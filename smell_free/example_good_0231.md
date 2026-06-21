```elixir
defmodule MyApp.Payments.LedgerEntry do
  @moduledoc """
  An immutable Ecto schema representing a double-entry ledger record.
  Every financial movement within the system produces exactly two ledger
  entries — one debit and one credit — ensuring the ledger always
  balances. The `transaction_id` field groups paired entries together.

  Entries are append-only: once inserted, they are never updated or deleted.
  Corrections are applied by inserting reversal entries with negated amounts.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias MyApp.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_entry_types [:debit, :credit]
  @valid_account_types [:revenue, :receivable, :payable, :liability, :expense, :equity]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          transaction_id: Ecto.UUID.t(),
          account_type: atom(),
          account_id: String.t(),
          entry_type: :debit | :credit,
          amount_cents: pos_integer(),
          currency: String.t(),
          description: String.t(),
          occurred_at: DateTime.t()
        }

  schema "ledger_entries" do
    field :transaction_id, :binary_id
    field :account_type, Ecto.Enum, values: @valid_account_types
    field :account_id, :string
    field :entry_type, Ecto.Enum, values: @valid_entry_types
    field :amount_cents, :integer
    field :currency, :string
    field :description, :string
    field :occurred_at, :utc_datetime

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc """
  Records a balanced pair of ledger entries (one debit, one credit) inside
  a single database transaction. Returns `{:ok, {debit, credit}}` or rolls
  back and returns `{:error, Ecto.Changeset.t()}` on any validation failure.
  """
  @spec record_transfer(map(), map(), String.t(), pos_integer(), String.t()) ::
          {:ok, {t(), t()}} | {:error, Ecto.Changeset.t()}
  def record_transfer(debit_account, credit_account, description, amount_cents, currency) do
    tx_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with {:ok, debit} <- insert_entry(tx_id, debit_account, :debit, amount_cents, currency, description, now),
           {:ok, credit} <- insert_entry(tx_id, credit_account, :credit, amount_cents, currency, description, now) do
        {debit, credit}
      else
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc "Returns the net balance in cents for `account_id` in `currency`."
  @spec balance(String.t(), String.t()) :: integer()
  def balance(account_id, currency) when is_binary(account_id) and is_binary(currency) do
    credits =
      __MODULE__
      |> where([e], e.account_id == ^account_id and e.entry_type == :credit and e.currency == ^currency)
      |> select([e], sum(e.amount_cents))
      |> Repo.one()
      |> Kernel.||(0)

    debits =
      __MODULE__
      |> where([e], e.account_id == ^account_id and e.entry_type == :debit and e.currency == ^currency)
      |> select([e], sum(e.amount_cents))
      |> Repo.one()
      |> Kernel.||(0)

    credits - debits
  end

  @spec insert_entry(String.t(), map(), atom(), pos_integer(), String.t(), String.t(), DateTime.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  defp insert_entry(tx_id, account, entry_type, amount_cents, currency, description, now) do
    %__MODULE__{}
    |> cast(%{
         transaction_id: tx_id,
         account_type: account.type,
         account_id: account.id,
         entry_type: entry_type,
         amount_cents: amount_cents,
         currency: currency,
         description: description,
         occurred_at: now
       }, [:transaction_id, :account_type, :account_id, :entry_type,
           :amount_cents, :currency, :description, :occurred_at])
    |> validate_required([:transaction_id, :account_type, :account_id, :entry_type,
                          :amount_cents, :currency, :description, :occurred_at])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> Repo.insert()
  end
end
```
