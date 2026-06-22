```elixir
defmodule Ledger.Accounts.TransactionContext do
  @moduledoc """
  Manages financial transaction processing for ledger accounts.

  Provides atomic balance updates and transaction history recording
  within bounded Ecto contexts.
  """

  alias Ledger.Repo
  alias Ledger.Accounts.{Account, Transaction}
  import Ecto.Query, warn: false

  @type transfer_params :: %{
          from_account_id: Ecto.UUID.t(),
          to_account_id: Ecto.UUID.t(),
          amount: Decimal.t(),
          description: String.t()
        }

  @type transfer_result ::
          {:ok, %{debit: Transaction.t(), credit: Transaction.t()}}
          | {:error, :insufficient_funds}
          | {:error, :account_not_found}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Executes an atomic transfer between two accounts.

  Returns `{:ok, %{debit: transaction, credit: transaction}}` on success.
  Returns `{:error, reason}` if validation or persistence fails.
  """
  @spec transfer(transfer_params()) :: transfer_result()
  def transfer(%{from_account_id: from_id, to_account_id: to_id, amount: amount} = params) do
    Repo.transaction(fn ->
      with {:ok, from_account} <- fetch_account(from_id),
           {:ok, to_account} <- fetch_account(to_id),
           :ok <- verify_sufficient_funds(from_account, amount),
           {:ok, debit} <- record_debit(from_account, amount, params.description),
           {:ok, credit} <- record_credit(to_account, amount, params.description) do
        %{debit: debit, credit: credit}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns paginated transaction history for a given account.
  """
  @spec list_transactions(Ecto.UUID.t(), pos_integer(), pos_integer()) ::
          {:ok, [Transaction.t()]} | {:error, :account_not_found}
  def list_transactions(account_id, page \\ 1, page_size \\ 20) do
    with {:ok, _account} <- fetch_account(account_id) do
      transactions =
        Transaction
        |> where([t], t.account_id == ^account_id)
        |> order_by([t], desc: t.inserted_at)
        |> limit(^page_size)
        |> offset(^((page - 1) * page_size))
        |> Repo.all()

      {:ok, transactions}
    end
  end

  defp fetch_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp verify_sufficient_funds(%Account{balance: balance}, amount) do
    if Decimal.compare(balance, amount) in [:gt, :eq] do
      :ok
    else
      {:error, :insufficient_funds}
    end
  end

  defp record_debit(account, amount, description) do
    new_balance = Decimal.sub(account.balance, amount)

    Repo.transaction(fn ->
      with {:ok, _} <- update_balance(account, new_balance),
           {:ok, txn} <- insert_transaction(account.id, :debit, amount, description) do
        txn
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_credit(account, amount, description) do
    new_balance = Decimal.add(account.balance, amount)

    Repo.transaction(fn ->
      with {:ok, _} <- update_balance(account, new_balance),
           {:ok, txn} <- insert_transaction(account.id, :credit, amount, description) do
        txn
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_balance(account, new_balance) do
    account
    |> Account.balance_changeset(%{balance: new_balance})
    |> Repo.update()
  end

  defp insert_transaction(account_id, kind, amount, description) do
    %Transaction{}
    |> Transaction.changeset(%{
      account_id: account_id,
      kind: kind,
      amount: amount,
      description: description
    })
    |> Repo.insert()
  end
end
```
