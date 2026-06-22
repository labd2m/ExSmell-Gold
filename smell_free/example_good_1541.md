```elixir
defmodule Ledger.AccountingEntry do
  @moduledoc """
  Double-entry accounting context for the internal financial ledger.

  Every debit must have a corresponding credit of equal magnitude. Entries
  are validated for balance before being written to the database inside
  an atomic transaction. All amounts are represented as integer cents to
  avoid floating-point precision issues.
  """

  alias Ledger.{Account, JournalEntry, JournalLine, Repo}
  alias Ecto.Multi

  @type line :: %{account_id: Ecto.UUID.t(), type: :debit | :credit, amount_cents: pos_integer()}
  @type entry_params :: %{description: String.t(), occurred_at: DateTime.t(), lines: [line()]}

  @type entry_result ::
          {:ok, JournalEntry.t()}
          | {:error, :unbalanced_entry}
          | {:error, :insufficient_lines}
          | {:error, :account_not_found, Ecto.UUID.t()}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Posts a balanced double-entry journal entry to the ledger.

  Requires at least two lines (one debit, one credit) where the sum of
  all debit amounts equals the sum of all credit amounts.
  """
  @spec post_entry(entry_params()) :: entry_result()
  def post_entry(%{lines: lines} = params) when length(lines) < 2 do
    _ = params
    {:error, :insufficient_lines}
  end

  def post_entry(%{lines: lines} = params) do
    with :ok <- validate_entry_balance(lines),
         :ok <- validate_accounts_exist(lines),
         {:ok, result} <- persist_entry(params) do
      {:ok, result.journal_entry}
    end
  end

  @doc """
  Returns the running balance for an account across all posted journal lines.

  Debits increase asset/expense accounts; credits increase liability/equity/revenue.
  """
  @spec account_balance(Ecto.UUID.t()) :: {:ok, integer()} | {:error, :account_not_found}
  def account_balance(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :account_not_found}

      account ->
        balance = compute_balance(account)
        {:ok, balance}
    end
  end

  defp validate_entry_balance(lines) do
    total_debits = lines |> Enum.filter(&(&1.type == :debit)) |> Enum.sum_by(& &1.amount_cents)
    total_credits = lines |> Enum.filter(&(&1.type == :credit)) |> Enum.sum_by(& &1.amount_cents)

    if total_debits == total_credits, do: :ok, else: {:error, :unbalanced_entry}
  end

  defp validate_accounts_exist(lines) do
    Enum.reduce_while(lines, :ok, fn %{account_id: id}, :ok ->
      case Repo.get(Account, id) do
        nil -> {:halt, {:error, :account_not_found, id}}
        _account -> {:cont, :ok}
      end
    end)
  end

  defp persist_entry(%{description: description, occurred_at: occurred_at, lines: lines}) do
    Multi.new()
    |> Multi.insert(:journal_entry, JournalEntry.changeset(%JournalEntry{}, %{
      description: description,
      occurred_at: occurred_at
    }))
    |> Multi.run(:journal_lines, fn _repo, %{journal_entry: entry} ->
      insert_journal_lines(entry.id, lines)
    end)
    |> Repo.transaction()
  end

  defp insert_journal_lines(entry_id, lines) do
    results =
      Enum.map(lines, fn line ->
        %JournalLine{}
        |> JournalLine.changeset(Map.put(line, :journal_entry_id, entry_id))
        |> Repo.insert()
      end)

    errors = Enum.filter(results, fn r -> match?({:error, _}, r) end)

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, l} -> l end)}
      [first_error | _] -> first_error
    end
  end

  defp compute_balance(%Account{id: account_id, normal_balance: :debit}) do
    debit_sum = sum_lines(account_id, :debit)
    credit_sum = sum_lines(account_id, :credit)
    debit_sum - credit_sum
  end

  defp compute_balance(%Account{id: account_id, normal_balance: :credit}) do
    credit_sum = sum_lines(account_id, :credit)
    debit_sum = sum_lines(account_id, :debit)
    credit_sum - debit_sum
  end

  defp sum_lines(account_id, type) do
    import Ecto.Query

    Repo.aggregate(
      from(l in JournalLine, where: l.account_id == ^account_id and l.type == ^type),
      :sum,
      :amount_cents
    ) || 0
  end
end
```
