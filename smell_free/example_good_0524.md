```elixir
defmodule Finance.LedgerContext do
  @moduledoc """
  Manages double-entry ledger accounts and journal entries. Every financial
  mutation is recorded as a balanced journal entry with debit and credit
  legs. Unbalanced entries are rejected by the changeset layer before
  reaching the database. Account balances are derived from entries to
  preserve a full audit trail with no destructive updates.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Finance.{Account, JournalEntry, EntryLeg}

  @type account_id :: Ecto.UUID.t()
  @type amount_cents :: integer()

  @doc "Opens a new ledger account of the given type."
  @spec open_account(String.t(), :asset | :liability | :equity | :revenue | :expense) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def open_account(name, type)
      when is_binary(name) and type in [:asset, :liability, :equity, :revenue, :expense] do
    %Account{} |> Account.changeset(%{name: name, type: type}) |> Repo.insert()
  end

  @doc """
  Posts a balanced journal entry. `legs` is a list of
  `%{account_id, side: :debit | :credit, amount_cents}` maps.
  Returns `{:error, :unbalanced_entry}` when debits do not equal credits.
  """
  @spec post_entry(String.t(), [map()]) ::
          {:ok, JournalEntry.t()} | {:error, :unbalanced_entry | Ecto.Changeset.t()}
  def post_entry(description, legs)
      when is_binary(description) and is_list(legs) do
    case check_balance(legs) do
      :ok ->
        Repo.transaction(fn ->
          with {:ok, entry} <- insert_journal_entry(description),
               :ok <- insert_legs(entry.id, legs) do
            Repo.preload(entry, :legs)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      {:error, :unbalanced_entry} ->
        {:error, :unbalanced_entry}
    end
  end

  @doc "Returns the current balance of `account_id` in cents."
  @spec balance(account_id()) :: {:ok, amount_cents()} | {:error, :not_found}
  def balance(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{type: type} ->
        debit_sum = sum_legs(account_id, :debit)
        credit_sum = sum_legs(account_id, :credit)
        balance = compute_balance(type, debit_sum, credit_sum)
        {:ok, balance}
    end
  end

  @doc "Returns all journal entries affecting `account_id` in chronological order."
  @spec history(account_id()) :: [JournalEntry.t()]
  def history(account_id) when is_binary(account_id) do
    from(e in JournalEntry,
      join: l in EntryLeg, on: l.journal_entry_id == e.id,
      where: l.account_id == ^account_id,
      order_by: [asc: e.inserted_at],
      distinct: e.id,
      preload: [:legs]
    )
    |> Repo.all()
  end

  defp check_balance(legs) do
    debits = legs |> Enum.filter(&(&1.side == :debit)) |> Enum.sum_by(& &1.amount_cents)
    credits = legs |> Enum.filter(&(&1.side == :credit)) |> Enum.sum_by(& &1.amount_cents)
    if debits == credits, do: :ok, else: {:error, :unbalanced_entry}
  end

  defp insert_journal_entry(description) do
    %JournalEntry{} |> JournalEntry.changeset(%{description: description}) |> Repo.insert()
  end

  defp insert_legs(entry_id, legs) do
    Enum.reduce_while(legs, :ok, fn leg, _acc ->
      attrs = Map.put(leg, :journal_entry_id, entry_id)
      case %EntryLeg{} |> EntryLeg.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end

  defp sum_legs(account_id, side) do
    from(l in EntryLeg,
      where: l.account_id == ^account_id and l.side == ^side,
      select: sum(l.amount_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp compute_balance(type, debits, credits) when type in [:asset, :expense], do: debits - credits
  defp compute_balance(_type, debits, credits), do: credits - debits
end
```
