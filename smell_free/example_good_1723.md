```elixir
defmodule Finance.LedgerEntry do
  @moduledoc """
  Struct and changeset logic for double-entry ledger records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: String.t(),
          contra_account_id: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          direction: :debit | :credit,
          reference: String.t(),
          posted_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "ledger_entries" do
    field :account_id, :string
    field :contra_account_id, :string
    field :amount_cents, :integer
    field :currency, :string
    field :direction, Ecto.Enum, values: [:debit, :credit]
    field :reference, :string
    field :posted_at, :utc_datetime_usec
    timestamps()
  end

  @required [:account_id, :contra_account_id, :amount_cents, :currency, :direction, :reference, :posted_at]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> validate_format(:reference, ~r/^[A-Z0-9\-]+$/)
  end
end

defmodule Finance.Ledger do
  @moduledoc """
  Records double-entry bookkeeping transactions against named accounts.

  Every transaction produces two balanced ledger entries (a debit and
  a credit). Both entries are written atomically within a single
  database transaction.
  """

  alias Finance.Repo
  alias Finance.LedgerEntry

  @type account_id :: String.t()
  @type currency :: String.t()
  @type amount_cents :: pos_integer()
  @type reference :: String.t()

  @type post_result ::
          {:ok, %{debit: LedgerEntry.t(), credit: LedgerEntry.t()}}
          | {:error, :invalid_entry, Ecto.Changeset.t()}

  @doc """
  Posts a balanced debit/credit pair to the ledger.

  The `debit_account` is debited and the `credit_account` is credited
  for the same amount. Both entries share the same `reference` for
  traceability.
  """
  @spec post(account_id(), account_id(), amount_cents(), currency(), reference()) :: post_result()
  def post(debit_account, credit_account, amount_cents, currency, reference)
      when is_binary(debit_account) and is_binary(credit_account) and
             is_integer(amount_cents) and amount_cents > 0 and
             is_binary(currency) and byte_size(currency) == 3 and
             is_binary(reference) do
    now = DateTime.utc_now()

    debit_attrs = build_entry(debit_account, credit_account, amount_cents, currency, :debit, reference, now)
    credit_attrs = build_entry(credit_account, debit_account, amount_cents, currency, :credit, reference, now)

    Repo.transaction(fn ->
      with {:ok, debit_entry} <- insert_entry(debit_attrs),
           {:ok, credit_entry} <- insert_entry(credit_attrs) do
        %{debit: debit_entry, credit: credit_entry}
      else
        {:error, changeset} -> Repo.rollback({:invalid_entry, changeset})
      end
    end)
    |> unwrap_post_result()
  end

  @doc """
  Returns the running balance for an account in the given currency.

  Credits increase the balance; debits decrease it.
  """
  @spec balance(account_id(), currency()) :: integer()
  def balance(account_id, currency) when is_binary(account_id) and is_binary(currency) do
    import Ecto.Query

    credits =
      Repo.aggregate(
        from(e in LedgerEntry,
          where: e.account_id == ^account_id and e.currency == ^currency and e.direction == :credit
        ),
        :sum,
        :amount_cents
      ) || 0

    debits =
      Repo.aggregate(
        from(e in LedgerEntry,
          where: e.account_id == ^account_id and e.currency == ^currency and e.direction == :debit
        ),
        :sum,
        :amount_cents
      ) || 0

    credits - debits
  end

  @spec build_entry(account_id(), account_id(), amount_cents(), currency(), atom(), reference(), DateTime.t()) :: map()
  defp build_entry(account_id, contra_id, amount, currency, direction, reference, posted_at) do
    %{
      account_id: account_id,
      contra_account_id: contra_id,
      amount_cents: amount,
      currency: currency,
      direction: direction,
      reference: reference,
      posted_at: posted_at
    }
  end

  @spec insert_entry(map()) :: {:ok, LedgerEntry.t()} | {:error, Ecto.Changeset.t()}
  defp insert_entry(attrs) do
    Repo.insert(LedgerEntry.changeset(%LedgerEntry{}, attrs))
  end

  @spec unwrap_post_result({:ok, map()} | {:error, term()}) :: post_result()
  defp unwrap_post_result({:ok, entries}), do: {:ok, entries}
  defp unwrap_post_result({:error, {:invalid_entry, cs}}), do: {:error, :invalid_entry, cs}
  defp unwrap_post_result({:error, reason}), do: {:error, reason}
end
```
