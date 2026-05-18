```elixir
defmodule Billing.WebhookProcessor do
  @moduledoc """
  Processes incoming webhook events from the payment gateway.
  Events are validated, parsed, and dispatched to the appropriate handler.
  """

  require Logger

  alias Billing.{EventStore, RefundHandler, ChargeHandler, DisputeHandler}

  @supported_events ~w(
    charge.succeeded
    charge.failed
    charge.refunded
    dispute.created
    dispute.updated
    customer.created
    customer.deleted
  )

  @spec process(map()) :: {:ok, term()} | {:error, term()}
  def process(%{"type" => type, "data" => data, "id" => event_id} = raw_payload) do
    Logger.info("Received webhook event", event_id: event_id, type: type)

    with {:ok, event_type} <- parse_event_type(type),
         {:ok, normalized} <- normalize_payload(data, event_type),
         :ok <- EventStore.persist(event_id, raw_payload),
         {:ok, result} <- dispatch(event_type, normalized) do
      Logger.info("Webhook processed successfully", event_id: event_id)
      {:ok, result}
    else
      {:error, :unsupported_event} ->
        Logger.warning("Unsupported webhook event type", type: type)
        {:ok, :skipped}

      {:error, reason} ->
        Logger.error("Webhook processing failed",
          event_id: event_id,
          type: type,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  def process(payload) do
    Logger.error("Malformed webhook payload", payload: inspect(payload))
    {:error, :malformed_payload}
  end

  defp parse_event_type(type) when is_binary(type) do
    if type in @supported_events do
      {:ok, String.to_atom(type)}
    else
      {:error, :unsupported_event}
    end
  end

  defp parse_event_type(_), do: {:error, :invalid_event_type}

  defp normalize_payload(data, event_type) do
    case event_type do
      :"charge.succeeded" ->
        {:ok, %{
          charge_id: data["id"],
          amount: data["amount"],
          currency: data["currency"],
          customer_id: data["customer"],
          captured_at: parse_timestamp(data["created"])
        }}

      :"charge.failed" ->
        {:ok, %{
          charge_id: data["id"],
          failure_code: data["failure_code"],
          failure_message: data["failure_message"],
          customer_id: data["customer"]
        }}

      :"charge.refunded" ->
        {:ok, %{
          charge_id: data["id"],
          amount_refunded: data["amount_refunded"],
          customer_id: data["customer"],
          refunded_at: parse_timestamp(data["created"])
        }}

      :"dispute.created" ->
        {:ok, %{
          dispute_id: data["id"],
          charge_id: data["charge"],
          amount: data["amount"],
          reason: data["reason"]
        }}

      :"dispute.updated" ->
        {:ok, %{
          dispute_id: data["id"],
          status: data["status"],
          charge_id: data["charge"]
        }}

      _ ->
        {:ok, data}
    end
  end

  defp dispatch(:"charge.succeeded", payload), do: ChargeHandler.handle_success(payload)
  defp dispatch(:"charge.failed", payload), do: ChargeHandler.handle_failure(payload)
  defp dispatch(:"charge.refunded", payload), do: RefundHandler.process(payload)
  defp dispatch(:"dispute.created", payload), do: DisputeHandler.open(payload)
  defp dispatch(:"dispute.updated", payload), do: DisputeHandler.update(payload)
  defp dispatch(_event_type, _payload), do: {:ok, :no_handler}

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
  end
end
```
