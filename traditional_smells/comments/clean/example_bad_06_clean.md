```elixir
defmodule PaymentGateway do
  @moduledoc """
  Abstracts communication with the upstream payment processor, providing
  charge, refund, and dispute management capabilities.
  """

  alias PaymentGateway.{
    CardToken,
    ChargeRecord,
    RefundRecord,
    ProcessorClient,
    IdempotencyKeyStore
  }

  @max_retries 3
  @retry_backoff_ms 500
  @supported_currencies ~w(USD EUR GBP BRL AUD)

  @doc """
  Validates a raw card token against the processor's tokenization service.
  """
  def validate_token(raw_token) do
    ProcessorClient.validate(raw_token)
  end

  # charge_card/2
  #
  # Submits a charge request to the upstream payment processor for the
  # amount and currency specified in `charge_params`.
  #
  # Idempotency is handled via an idempotency key derived from
  # `charge_params.order_id`. If a charge for the same order_id has already
  # been successfully processed, the function returns the existing
  # ChargeRecord without re-charging the card.
  #
  # Transient network failures are retried up to @max_retries times with
  # exponential backoff starting at @retry_backoff_ms milliseconds.
  #
  # charge_params fields:
  #   :token        - CardToken struct (pre-validated)
  #   :amount_cents - positive integer (e.g. 4999 for $49.99)
  #   :currency     - ISO 4217 string, must be in @supported_currencies
  #   :order_id     - string, used as idempotency key base
  #   :metadata     - optional map of additional key/value pairs
  #
  # Returns:
  #   {:ok, %ChargeRecord{}} on success
  #   {:error, :idempotent_replay, existing_record} if already charged
  #   {:error, :unsupported_currency} if currency not supported
  #   {:error, processor_error_map} on processor decline or failure
  # idempotency semantics, retry policy, accepted fields, and all error cases —
  # is conveyed exclusively through plain inline comments rather than @doc,
  # making the information inaccessible to documentation generators and IEx.
  def charge_card(%CardToken{} = token, charge_params) do
    idempotency_key = build_idempotency_key(charge_params.order_id)

    with :ok <- validate_currency(charge_params.currency),
         {:ok, :new} <- IdempotencyKeyStore.check_or_reserve(idempotency_key),
         {:ok, processor_response} <- retry_charge(token, charge_params, @max_retries),
         {:ok, record} <- ChargeRecord.create(charge_params, processor_response) do
      IdempotencyKeyStore.commit(idempotency_key, record.id)
      {:ok, record}
    else
      {:ok, :replay, existing_id} ->
        {:ok, record} = ChargeRecord.fetch(existing_id)
        {:error, :idempotent_replay, record}

      {:error, reason} ->
        IdempotencyKeyStore.release(idempotency_key)
        {:error, reason}
    end
  end

  @doc """
  Issues a full or partial refund for a previously captured charge.
  """
  def refund_charge(charge_id, amount_cents \\ :full) do
    with {:ok, charge} <- ChargeRecord.fetch(charge_id),
         {:ok, refund_amount} <- resolve_refund_amount(charge, amount_cents),
         {:ok, response} <- ProcessorClient.refund(charge.processor_id, refund_amount) do
      RefundRecord.create(charge_id, refund_amount, response)
    end
  end

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(_), do: {:error, :unsupported_currency}

  defp build_idempotency_key(order_id), do: "charge:#{order_id}"

  defp retry_charge(_token, _params, 0), do: {:error, :max_retries_exceeded}

  defp retry_charge(token, params, attempts_left) do
    case ProcessorClient.charge(token, params) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{retryable: true}} ->
        Process.sleep(@retry_backoff_ms * (@max_retries - attempts_left + 1))
        retry_charge(token, params, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_refund_amount(charge, :full), do: {:ok, charge.amount_cents}

  defp resolve_refund_amount(charge, partial) when partial > 0 and partial <= charge.amount_cents,
    do: {:ok, partial}

  defp resolve_refund_amount(_, _), do: {:error, :invalid_refund_amount}
end
```
