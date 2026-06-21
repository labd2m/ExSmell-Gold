# File: `example_good_193.md`

```elixir
defmodule Ledger.DoubleEntry do
  @moduledoc """
  Double-entry bookkeeping context for recording financial transactions
  as balanced debit/credit journal entries.

  Every recorded transaction must balance to zero across all legs.
  The context enforces this invariant at the boundary so no unbalanced
  state can reach the database.
  """

  import Ecto.Query, warn: false

  alias Ledger.{Account, Entry, JournalLine, Repo}

  @type account_id :: Ecto.UUID.t()
  @type amount_cents :: integer()

  @type leg :: %{
          required(:account_id) => account_id(),
          required(:amount_cents) => amount_cents()
        }

  @type entry_result ::
          {:ok, Entry.t()}
          | {:error, :unbalanced_entry}
          | {:error, :empty_legs}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Records a balanced journal entry consisting of two or more legs.

  The sum of all leg amounts must equal zero (debits positive,
  credits negative). Returns `{:error, :unbalanced_entry}` when
  the legs do not net to zero.
  """
  @spec record(String.t(), [leg()], String.t()) :: entry_result()
  def record(description, legs, currency)
      when is_binary(description) and is_list(legs) and is_binary(currency) do
    with :ok <- validate_legs(legs),
         :ok <- validate_balance(legs),
         {:ok, entry} <- insert_entry(description, currency, legs) do
      {:ok, entry}
    end
  end

  @doc """
  Returns the current balance of an account in its native currency.

  Balances are computed directly from journal lines to ensure
  consistency with the ledger rather than relying on a cached value.
  """
  @spec balance(account_id()) :: amount_cents()
  def balance(account_id) when is_binary(account_id) do
    JournalLine
    |> where([l], l.account_id == ^account_id)
    |> select([l], sum(l.amount_cents))
    |> Repo.one()
    |> coerce_sum()
  end

  @doc """
  Returns all journal entries touching a given account, ordered by
  most recent first, with their associated lines preloaded.
  """
  @spec history(account_id(), pos_integer()) :: [Entry.t()]
  def history(account_id, limit \\ 50)
      when is_binary(account_id) and is_integer(limit) and limit > 0 do
    Entry
    |> join(:inner, [e], l in JournalLine, on: l.entry_id == e.id)
    |> where([_e, l], l.account_id == ^account_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> preload(:lines)
    |> Repo.all()
  end

  @doc """
  Returns the aggregate balance movements for an account within a
  date range, grouped by calendar month.
  """
  @spec monthly_movements(account_id(), Date.t(), Date.t()) :: [map()]
  def monthly_movements(account_id, from_date, to_date)
      when is_binary(account_id) do
    JournalLine
    |> join(:inner, [l], e in Entry, on: e.id == l.entry_id)
    |> where([l, e],
      l.account_id == ^account_id and
        fragment("DATE(?) >= ?", e.inserted_at, ^from_date) and
        fragment("DATE(?) <= ?", e.inserted_at, ^to_date)
    )
    |> group_by([_l, e], fragment("DATE_TRUNC('month', ?)", e.inserted_at))
    |> select([l, e], %{
      month: fragment("DATE_TRUNC('month', ?)", e.inserted_at),
      net_cents: sum(l.amount_cents)
    })
    |> order_by([_l, e], asc: fragment("DATE_TRUNC('month', ?)", e.inserted_at))
    |> Repo.all()
  end

  defp validate_legs([]), do: {:error, :empty_legs}
  defp validate_legs([_]), do: {:error, :empty_legs}
  defp validate_legs(_legs), do: :ok

  defp validate_balance(legs) do
    total = Enum.sum(Enum.map(legs, & &1.amount_cents))

    if total == 0 do
      :ok
    else
      {:error, :unbalanced_entry}
    end
  end

  defp insert_entry(description, currency, legs) do
    Repo.transaction(fn ->
      entry =
        %{description: description, currency: currency}
        |> Entry.changeset()
        |> Repo.insert!()

      Enum.each(legs, fn leg ->
        %{entry_id: entry.id, account_id: leg.account_id, amount_cents: leg.amount_cents}
        |> JournalLine.changeset()
        |> Repo.insert!()
      end)

      entry
    end)
  end

  defp coerce_sum(nil), do: 0
  defp coerce_sum(n) when is_integer(n), do: n
end
```
