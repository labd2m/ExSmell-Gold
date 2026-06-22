```elixir
defmodule Payments.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "transfers" do
    field :from_account_id, :integer
    field :to_account_id, :integer
    field :amount_cents, :integer
    field :reference, :string
    field :status, :string, default: "completed"
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:from_account_id, :to_account_id, :amount_cents, :reference, :status])
    |> validate_required([:from_account_id, :to_account_id, :amount_cents, :reference])
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint(:reference)
  end
end

defmodule Payments.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "payment_accounts" do
    field :owner_id, :integer
    field :balance_cents, :integer, default: 0
    field :currency, :string
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:owner_id, :balance_cents, :currency])
    |> validate_required([:owner_id, :currency])
    |> validate_number(:balance_cents, greater_than_or_equal_to: 0)
  end
end

defmodule Payments.TransferService do
  @moduledoc """
  Executes fund transfers between accounts as atomic multi-step transactions.
  All operations within a single transfer either fully succeed or fully roll back.
  """

  alias Ecto.Multi
  alias Payments.{Repo, Account, Transfer}

  @type transfer_result ::
          {:ok, %{transfer: Transfer.t(), debit: Account.t(), credit: Account.t()}}
          | {:error, atom(), term(), map()}

  @spec execute(integer(), integer(), pos_integer(), String.t()) :: transfer_result()
  def execute(from_id, to_id, amount_cents, reference)
      when is_integer(from_id) and is_integer(to_id) and
             is_integer(amount_cents) and amount_cents > 0 and
             is_binary(reference) do
    Multi.new()
    |> Multi.run(:source, fn repo, _ -> fetch_account(repo, from_id) end)
    |> Multi.run(:destination, fn repo, _ -> fetch_account(repo, to_id) end)
    |> Multi.run(:debit, fn repo, %{source: source} ->
      debit_account(repo, source, amount_cents)
    end)
    |> Multi.run(:credit, fn repo, %{destination: dest} ->
      credit_account(repo, dest, amount_cents)
    end)
    |> Multi.insert(:transfer, fn %{source: src, destination: dst} ->
      Transfer.changeset(%Transfer{}, %{
        from_account_id: src.id,
        to_account_id: dst.id,
        amount_cents: amount_cents,
        reference: reference
      })
    end)
    |> Repo.transaction()
  end

  defp fetch_account(repo, id) do
    case repo.get(Account, id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp debit_account(repo, %Account{balance_cents: balance} = account, amount)
       when balance >= amount do
    account |> Account.changeset(%{balance_cents: balance - amount}) |> repo.update()
  end

  defp debit_account(_repo, %Account{}, _amount), do: {:error, :insufficient_funds}

  defp credit_account(repo, account, amount) do
    account
    |> Account.changeset(%{balance_cents: account.balance_cents + amount})
    |> repo.update()
  end
end
```
