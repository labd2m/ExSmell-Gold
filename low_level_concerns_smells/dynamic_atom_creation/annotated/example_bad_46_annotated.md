# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `parse_currency_code/1` function
- **Affected function(s):** `parse_currency_code/1`
- **Short explanation:** The function converts a currency code string from an incoming cross-border payment request into an atom using `String.to_atom/1`. Currency codes are submitted by API clients and, despite being nominally standardised, can include arbitrary or malformed strings in practice, creating an uncontrolled source of permanent atoms.

---

```elixir
defmodule Payments.CrossBorderTransfer do
  @moduledoc """
  Handles cross-border payment transfers between accounts held in different
  currencies. Applies FX conversion rates, validates compliance rules, and
  submits the transfer to the SWIFT gateway.
  """

  require Logger

  alias Payments.{
    FXRateProvider,
    ComplianceChecker,
    SWIFTGateway,
    TransferRepo,
    AccountRepo,
    AuditLogger
  }

  @max_transfer_amount_usd 500_000
  @min_transfer_amount_usd 1

  @spec initiate(map()) :: {:ok, map()} | {:error, term()}
  def initiate(%{
        "sender_account_id" => sender_id,
        "recipient_account_id" => recipient_id,
        "amount" => amount,
        "source_currency" => src_currency,
        "target_currency" => tgt_currency
      } = params) do
    Logger.info("Initiating cross-border transfer",
      sender: sender_id,
      recipient: recipient_id,
      amount: amount
    )

    with {:ok, src_ccy} <- parse_currency_code(src_currency),
         {:ok, tgt_ccy} <- parse_currency_code(tgt_currency),
         {:ok, sender} <- AccountRepo.get(sender_id),
         {:ok, recipient} <- AccountRepo.get(recipient_id),
         :ok <- validate_amount(amount, src_ccy),
         {:ok, fx_rate} <- FXRateProvider.get_rate(src_ccy, tgt_ccy),
         {:ok, converted_amount} <- apply_fx(amount, fx_rate),
         :ok <- ComplianceChecker.check(sender, recipient, amount, src_ccy),
         {:ok, transfer} <-
           TransferRepo.create(%{
             sender_account_id: sender.id,
             recipient_account_id: recipient.id,
             source_amount: amount,
             source_currency: src_ccy,
             target_amount: converted_amount,
             target_currency: tgt_ccy,
             fx_rate: fx_rate,
             reference: params["reference"],
             initiated_at: DateTime.utc_now()
           }),
         {:ok, swift_ref} <- SWIFTGateway.submit(transfer),
         {:ok, finalized} <- TransferRepo.mark_submitted(transfer.id, swift_ref) do
      AuditLogger.log(:transfer_initiated, %{transfer_id: transfer.id, swift_ref: swift_ref})
      Logger.info("Transfer submitted", transfer_id: transfer.id, swift_ref: swift_ref)
      {:ok, finalized}
    else
      {:error, reason} = err ->
        Logger.error("Transfer initiation failed",
          sender: sender_id,
          reason: inspect(reason)
        )
        err
    end
  end

  def initiate(_), do: {:error, :missing_required_fields}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is called on a
  # currency code string submitted by the API client. Although ISO 4217 defines
  # a fixed set of currency codes, clients can send any string value (including
  # malformed, unsupported, or future codes). Each unique string creates a new
  # permanent atom, and under high transfer volume or with adversarial input,
  # the atom table can grow without bound.
  defp parse_currency_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()
    {:ok, String.to_atom(normalized)}
  end
  # VALIDATION: SMELL END

  defp parse_currency_code(_), do: {:error, :invalid_currency_code}

  defp validate_amount(amount, currency) when is_number(amount) do
    usd_equivalent = FXRateProvider.to_usd_estimate(amount, currency)

    cond do
      usd_equivalent < @min_transfer_amount_usd ->
        {:error, :amount_too_small}

      usd_equivalent > @max_transfer_amount_usd ->
        {:error, :amount_exceeds_limit}

      true ->
        :ok
    end
  end

  defp validate_amount(_, _), do: {:error, :invalid_amount}

  defp apply_fx(amount, fx_rate) when is_number(amount) and is_number(fx_rate) do
    converted = Float.round(amount * fx_rate, 2)
    {:ok, converted}
  end

  defp apply_fx(_, _), do: {:error, :fx_conversion_failed}
end
```
