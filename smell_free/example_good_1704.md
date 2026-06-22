```elixir
defmodule Ledger.TransactionJournal do
  @moduledoc """
  Double-entry bookkeeping journal for financial transaction recording.
  Enforces balanced debits and credits before committing entries.
  """

  alias Ledger.{Entry, JournalRecord, Repo}
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3]

  @type account_id :: String.t()
  @type amount_cents :: pos_integer()
  @type entry_line :: %{account_id: account_id(), type: :debit | :credit, amount_cents: amount_cents()}
  @type journal_params :: %{description: String.t(), reference: String.t(), lines: [entry_line()]}

  @spec post(journal_params()) :: {:ok, JournalRecord.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def post(%{description: desc, reference: ref, lines: lines} = _params)
      when is_binary(desc) and is_binary(ref) and is_list(lines) do
    with :ok <- validate_balance(lines),
         :ok <- validate_line_count(lines) do
      Repo.transaction(fn ->
        case insert_journal_record(desc, ref, lines) do
          {:ok, record} -> record
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @spec account_balance(account_id()) :: integer()
  def account_balance(account_id) when is_binary(account_id) do
    debits = sum_entries(account_id, :debit)
    credits = sum_entries(account_id, :credit)
    debits - credits
  end

  @spec entries_for_account(account_id(), keyword()) :: [Entry.t()]
  def entries_for_account(account_id, opts \\ []) when is_binary(account_id) do
    from(e in Entry, where: e.account_id == ^account_id)
    |> apply_date_filter(opts)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @spec validate_balance([entry_line()]) :: :ok | {:error, String.t()}
  defp validate_balance(lines) do
    total_debits = lines |> Enum.filter(&(&1.type == :debit)) |> Enum.sum_by(& &1.amount_cents)
    total_credits = lines |> Enum.filter(&(&1.type == :credit)) |> Enum.sum_by(& &1.amount_cents)

    if total_debits == total_credits do
      :ok
    else
      {:error, "Journal entry is unbalanced: debits=#{total_debits}, credits=#{total_credits}"}
    end
  end

  @spec validate_line_count([entry_line()]) :: :ok | {:error, String.t()}
  defp validate_line_count(lines) when length(lines) < 2 do
    {:error, "Journal entry must have at least two lines"}
  end

  defp validate_line_count(_), do: :ok

  @spec insert_journal_record(String.t(), String.t(), [entry_line()]) ::
          {:ok, JournalRecord.t()} | {:error, Ecto.Changeset.t()}
  defp insert_journal_record(description, reference, lines) do
    with {:ok, record} <- Repo.insert(JournalRecord.changeset(%{description: description, reference: reference})) do
      results = Enum.map(lines, &insert_entry(record.id, &1))
      failed = Enum.find(results, &match?({:error, _}, &1))

      if failed do
        elem(failed, 1) |> then(&{:error, &1})
      else
        {:ok, record}
      end
    end
  end

  @spec insert_entry(String.t(), entry_line()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  defp insert_entry(journal_id, line) do
    %{journal_id: journal_id, account_id: line.account_id, type: line.type, amount_cents: line.amount_cents}
    |> Entry.changeset()
    |> Repo.insert()
  end

  @spec sum_entries(account_id(), :debit | :credit) :: non_neg_integer()
  defp sum_entries(account_id, type) do
    from(e in Entry,
      where: e.account_id == ^account_id and e.type == ^type,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end

  @spec apply_date_filter(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  defp apply_date_filter(query, opts) do
    case Keyword.get(opts, :since) do
      nil -> query
      date -> where(query, [e], e.inserted_at >= ^date)
    end
  end
end
```
