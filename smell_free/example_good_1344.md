```elixir
defmodule Ledger.Entry do
  @moduledoc """
  An immutable double-entry bookkeeping record. Every financial movement
  is represented as a pair of debit and credit lines that must balance
  to zero. Entries are append-only and identified by a globally unique
  idempotency key to prevent duplicate posting.
  """

  @enforce_keys [:id, :idempotency_key, :description, :lines, :posted_at]
  defstruct [:id, :idempotency_key, :description, :lines, :posted_at, :metadata]

  @type line :: %{
          account_id: String.t(),
          amount_cents: integer(),
          side: :debit | :credit,
          currency: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          idempotency_key: String.t(),
          description: String.t(),
          lines: list(line()),
          posted_at: DateTime.t(),
          metadata: map() | nil
        }

  @spec new(String.t(), String.t(), list(line()), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def new(idempotency_key, description, lines, opts \\ [])
      when is_binary(idempotency_key) and is_binary(description) and is_list(lines) do
    with :ok <- validate_lines(lines) do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         idempotency_key: idempotency_key,
         description: description,
         lines: lines,
         posted_at: Keyword.get(opts, :posted_at, DateTime.utc_now()),
         metadata: Keyword.get(opts, :metadata)
       }}
    end
  end

  @spec balanced?(t()) :: boolean()
  def balanced?(%__MODULE__{lines: lines}) do
    net = Enum.reduce(lines, 0, fn line, acc ->
      case line.side do
        :debit -> acc + line.amount_cents
        :credit -> acc - line.amount_cents
      end
    end)
    net == 0
  end

  @spec lines_for_account(t(), String.t()) :: list(line())
  def lines_for_account(%__MODULE__{lines: lines}, account_id) when is_binary(account_id) do
    Enum.filter(lines, &(&1.account_id == account_id))
  end

  defp validate_lines([]), do: {:error, :empty_lines}

  defp validate_lines(lines) do
    cond do
      Enum.any?(lines, &(not is_integer(&1.amount_cents) or &1.amount_cents <= 0)) ->
        {:error, :invalid_line_amounts}

      Enum.any?(lines, &(&1.side not in [:debit, :credit])) ->
        {:error, :invalid_line_side}

      not check_balance(lines) ->
        {:error, :unbalanced_entry}

      true ->
        :ok
    end
  end

  defp check_balance(lines) do
    net = Enum.reduce(lines, 0, fn line, acc ->
      case line.side do
        :debit -> acc + line.amount_cents
        :credit -> acc - line.amount_cents
      end
    end)

    net == 0
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end

defmodule Ledger.AccountBalance do
  @moduledoc """
  Computes running balances for accounts from a list of posted entries.
  All calculations are pure — no database interaction required.
  """

  alias Ledger.Entry

  @type balance_map :: %{String.t() => integer()}

  @spec compute(list(Entry.t())) :: balance_map()
  def compute(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, &apply_entry/2)
  end

  @spec compute_for_account(list(Entry.t()), String.t()) :: integer()
  def compute_for_account(entries, account_id) when is_list(entries) and is_binary(account_id) do
    entries
    |> compute()
    |> Map.get(account_id, 0)
  end

  @spec net_movement(list(Entry.t()), String.t(), DateTime.t(), DateTime.t()) :: integer()
  def net_movement(entries, account_id, from_dt, to_dt)
      when is_binary(account_id) do
    entries
    |> Enum.filter(fn e ->
      DateTime.compare(e.posted_at, from_dt) in [:gt, :eq] and
        DateTime.compare(e.posted_at, to_dt) == :lt
    end)
    |> compute_for_account(account_id)
  end

  defp apply_entry(%Entry{lines: lines}, balance_map) do
    Enum.reduce(lines, balance_map, fn line, acc ->
      delta = line_delta(line)
      Map.update(acc, line.account_id, delta, &(&1 + delta))
    end)
  end

  defp line_delta(%{side: :debit, amount_cents: amount}), do: amount
  defp line_delta(%{side: :credit, amount_cents: amount}), do: -amount
end

defmodule Ledger.Journal do
  @moduledoc """
  Ecto-backed journal that persists and queries `Ledger.Entry` records.
  Duplicate entries are silently ignored using the idempotency key constraint.
  """

  import Ecto.Query, warn: false

  alias Ledger.{Repo, Entry, AccountBalance}

  @spec post(Entry.t()) :: {:ok, Entry.t()} | {:error, :duplicate} | {:error, Ecto.Changeset.t()}
  def post(%Entry{} = entry) do
    params = %{
      id: entry.id,
      idempotency_key: entry.idempotency_key,
      description: entry.description,
      lines: Jason.encode!(entry.lines),
      posted_at: entry.posted_at,
      metadata: entry.metadata
    }

    case Repo.insert_all("ledger_entries", [params], on_conflict: :nothing, returning: true) do
      {1, [_row]} -> {:ok, entry}
      {0, _} -> {:error, :duplicate}
    end
  end

  @spec entries_for_account(String.t(), keyword()) :: list(Entry.t())
  def entries_for_account(account_id, opts \\ []) when is_binary(account_id) do
    limit = Keyword.get(opts, :limit, 500)

    "ledger_entries"
    |> where([e], fragment("lines::text LIKE ?", ^"%#{account_id}%"))
    |> order_by([e], desc: e.posted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&deserialize_entry/1)
  end

  @spec account_balance(String.t()) :: integer()
  def account_balance(account_id) when is_binary(account_id) do
    account_id
    |> entries_for_account()
    |> AccountBalance.compute_for_account(account_id)
  end

  defp deserialize_entry(row) do
    %Entry{
      id: row.id,
      idempotency_key: row.idempotency_key,
      description: row.description,
      lines: Jason.decode!(row.lines, keys: :atoms),
      posted_at: row.posted_at,
      metadata: row.metadata
    }
  end
end
```
