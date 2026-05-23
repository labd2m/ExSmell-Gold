```elixir
defmodule Banking.Transfers do
  @moduledoc """
  Handles fund transfers between accounts.
  Supports domestic ACH and international SWIFT transfers
  with appropriate fee schedules and compliance checks.
  """

  alias Banking.Repo
  alias Banking.Account
  alias Banking.Transfer
  alias Banking.ComplianceChecker

  @domestic_fee_cents 25
  @international_fee_cents 2500

  @doc """
  Initiates a domestic ACH transfer from one account to another.
  Amount is in cents.
  """
  def initiate_domestic(from_account_id, to_account_id, amount_cents) do
    with {:ok, sender} <- fetch_active_account(from_account_id),
         {:ok, receiver} <- fetch_active_account(to_account_id) do

      total_required = amount_cents + @domestic_fee_cents

      if sender.available_balance_cents < total_required do
        {:error, :insufficient_funds}
      else
        {:ok, {sender, receiver, total_required}}
      end
    end
    |> case do
      {:ok, {sender, receiver, total_required}} ->
        transfer = %Transfer{
          from_account_id: sender.id,
          to_account_id: receiver.id,
          amount_cents: amount_cents,
          fee_cents: @domestic_fee_cents,
          type: :domestic_ach,
          status: :pending
        }

        Repo.insert!(transfer)
        Repo.update!(%{sender | available_balance_cents: sender.available_balance_cents - total_required})
        {:ok, transfer}

      error ->
        error
    end
  end

  @doc """
  Initiates an international SWIFT transfer.
  Includes compliance screening before processing.
  Amount is in cents.
  """
  def initiate_international(from_account_id, to_account_id, amount_cents) do
    with {:ok, sender} <- fetch_active_account(from_account_id),
         {:ok, receiver} <- fetch_active_account(to_account_id),
         :ok <- ComplianceChecker.screen(sender, receiver) do

      total_required = amount_cents + @international_fee_cents

      if sender.available_balance_cents < total_required do
        {:error, :insufficient_funds}
      else
        {:ok, {sender, receiver, total_required}}
      end
    end
    |> case do
      {:ok, {sender, receiver, total_required}} ->
        transfer = %Transfer{
          from_account_id: sender.id,
          to_account_id: receiver.id,
          amount_cents: amount_cents,
          fee_cents: @international_fee_cents,
          type: :international_swift,
          status: :pending
        }

        Repo.insert!(transfer)
        Repo.update!(%{sender | available_balance_cents: sender.available_balance_cents - total_required})
        {:ok, transfer}

      error ->
        error
    end
  end

  @doc """
  Returns recent transfers for an account (last 90 days).
  """
  def recent_transfers(account_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -90 * 86_400, :second)
    Repo.all_by(Transfer, account_id: account_id, after: cutoff)
  end

  defp fetch_active_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :account_not_found}
      %Account{status: :active} = acct -> {:ok, acct}
      _ -> {:error, :account_not_active}
    end
  end
end
```
