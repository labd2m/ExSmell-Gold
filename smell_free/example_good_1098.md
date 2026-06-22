```elixir
defmodule Ledger.Accounts.Entry do
  @moduledoc """
  Represents a double-entry bookkeeping record for a financial account.
  Each entry carries an amount, a direction, and a reference to its parent transaction.
  """

  @type direction :: :debit | :credit

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          transaction_id: Ecto.UUID.t(),
          direction: direction(),
          amount_cents: pos_integer(),
          currency: String.t(),
          description: String.t(),
          posted_at: DateTime.t()
        }

  defstruct [:id, :account_id, :transaction_id, :direction, :amount_cents, :currency,
             :description, :posted_at]
end

defmodule Ledger.Accounts do
  @moduledoc """
  Context for managing ledger accounts and their associated entries.
  All balance computations are performed in integer cents to avoid floating-point drift.
  """

  alias Ledger.Accounts.Entry
  alias Ledger.Repo
  import Ecto.Query

  @type balance_result :: {:ok, integer()} | {:error, :account_not_found}

  @doc """
  Returns the running balance for an account in cents as of a given datetime.
  Debits increase the balance; credits decrease it.
  """
  @spec balance_at(Ecto.UUID.t(), DateTime.t()) :: balance_result()
  def balance_at(account_id, %DateTime{} = as_of) when is_binary(account_id) do
    case account_exists?(account_id) do
      false -> {:error, :account_not_found}
      true -> {:ok, compute_balance(account_id, as_of)}
    end
  end

  @doc """
  Returns a list of entries for an account sorted by posting date ascending.
  """
  @spec entries_for(Ecto.UUID.t()) :: {:ok, [Entry.t()]} | {:error, :account_not_found}
  def entries_for(account_id) when is_binary(account_id) do
    case account_exists?(account_id) do
      false -> {:error, :account_not_found}
      true -> {:ok, fetch_entries(account_id)}
    end
  end

  @doc """
  Records a new ledger entry after validating that amount is a positive integer
  and that direction is a known atom.
  """
  @spec record_entry(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record_entry(attrs) when is_map(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp account_exists?(account_id) do
    Repo.exists?(from a in "accounts", where: a.id == ^account_id)
  end

  defp compute_balance(account_id, as_of) do
    debit_sum = sum_direction(account_id, :debit, as_of)
    credit_sum = sum_direction(account_id, :credit, as_of)
    debit_sum - credit_sum
  end

  defp sum_direction(account_id, direction, as_of) do
    from(e in "ledger_entries",
      where:
        e.account_id == ^account_id and
          e.direction == ^to_string(direction) and
          e.posted_at <= ^as_of,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end

  defp fetch_entries(account_id) do
    from(e in Entry, where: e.account_id == ^account_id, order_by: [asc: e.posted_at])
    |> Repo.all()
  end
end
```
