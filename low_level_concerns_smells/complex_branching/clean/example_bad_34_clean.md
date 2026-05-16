# Example 34

```elixir
defmodule Payments.FundsTransfer do
  @moduledoc """
  Orchestrates domestic and international funds transfers via the BankBridge API.
  Enforces daily limits, compliance checks, and idempotency.
  """

  require Logger

  alias Payments.Repo
  alias Payments.Schema.{Transfer, Account, ComplianceFlag}
  alias Payments.BankBridge.Client
  alias Payments.Compliance

  @daily_limit_usd 50_000_00
  @supported_transfer_types [:domestic, :international, :internal]

  def initiate(from_account_id, to_account_id, amount_cents, opts \\ []) do
    type = Keyword.get(opts, :type, :domestic)
    currency = Keyword.get(opts, :currency, "USD")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    with {:ok, from} <- fetch_account(from_account_id),
         {:ok, to} <- fetch_account(to_account_id),
         :ok <- check_daily_limit(from, amount_cents),
         :ok <- Compliance.screen(from, to, amount_cents),
         {:ok, payload} <- build_transfer_payload(from, to, amount_cents, currency, type, idempotency_key) do
      execute_transfer(from, Client.post("/transfers", payload))
    end
  end

  defp fetch_account(id) do
    case Repo.get(Account, id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp check_daily_limit(%Account{daily_transferred: daily}, amount)
       when daily + amount > @daily_limit_usd,
       do: {:error, :daily_limit_exceeded}

  defp check_daily_limit(_, _), do: :ok

  defp build_transfer_payload(from, to, amount, currency, type, key) do
    {:ok,
     %{
       source_account: from.external_id,
       destination_account: to.external_id,
       amount: amount,
       currency: currency,
       type: type,
       idempotency_key: key
     }}
  end

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16()

  defp execute_transfer(account, bank_response) do
    case bank_response do
      {:ok, %{status: 201, body: %{"transfer_id" => tid, "status" => "completed"}}} ->
        Logger.info("Transfer #{tid} completed for account #{account.id}")

        {:ok, transfer} =
          Repo.insert(%Transfer{
            account_id: account.id,
            external_id: tid,
            status: :completed
          })

        {:ok, transfer}

      {:ok, %{status: 202, body: %{"transfer_id" => tid, "status" => "pending"}}} ->
        Logger.info("Transfer #{tid} pending settlement for account #{account.id}")

        {:ok, transfer} =
          Repo.insert(%Transfer{
            account_id: account.id,
            external_id: tid,
            status: :pending
          })

        {:ok, transfer}

      {:ok, %{status: 200, body: %{"transfer_id" => tid, "status" => "duplicate"}}} ->
        Logger.info("Duplicate transfer detected #{tid} for account #{account.id}")
        {:ok, :duplicate}

      {:ok, %{status: 402, body: %{"error" => "insufficient_balance"}}} ->
        Logger.warning("Insufficient balance on account #{account.id}")
        {:error, :insufficient_balance}

      {:ok, %{status: 403, body: %{"error" => "compliance_hold", "case_id" => case_id}}} ->
        Logger.error("Compliance hold on account #{account.id}, case #{case_id}")

        Repo.insert(%ComplianceFlag{
          account_id: account.id,
          case_id: case_id,
          reason: :transfer_hold
        })

        {:error, :compliance_hold}

      {:ok, %{status: 404, body: %{"error" => "destination_not_found"}}} ->
        Logger.warning("Destination account not found for account #{account.id}")
        {:error, :destination_not_found}

      {:ok, %{status: 409, body: %{"error" => "account_closed"}}} ->
        Logger.warning("Destination account closed for account #{account.id}")
        {:error, :destination_account_closed}

      {:ok, %{status: 422, body: %{"error" => "currency_mismatch"}}} ->
        Logger.warning("Currency mismatch for account #{account.id}")
        {:error, :currency_mismatch}

      {:ok, %{status: 422, body: %{"error" => "amount_below_minimum"}}} ->
        Logger.warning("Amount below minimum for account #{account.id}")
        {:error, :amount_below_minimum}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by BankBridge for account #{account.id}")
        {:error, :rate_limited}

      {:ok, %{status: 500, body: body}} ->
        Logger.error("BankBridge internal error for account #{account.id}: #{inspect(body)}")
        {:error, :bank_internal_error}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("BankBridge unavailable for account #{account.id}")
        {:error, :bank_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected BankBridge status #{status} for account #{account.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("BankBridge timeout for account #{account.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("BankBridge error for account #{account.id}: #{inspect(reason)}")
        {:error, {:bank_error, reason}}
    end
  end

  def pending_transfers(account_id) do
    Transfer
    |> Transfer.pending_for_account(account_id)
    |> Repo.all()
  end
end
```
