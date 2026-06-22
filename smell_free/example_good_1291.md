```elixir
defmodule Billing.WebhookHandler do
  @moduledoc """
  Processes inbound Stripe webhook events with idempotency guarantees.

  Each event is deduplicated by its Stripe event ID before dispatching to
  the appropriate domain handler. Signature verification is delegated to
  a configurable verifier module, allowing test injection.
  """

  alias Billing.WebhookHandler.{EventRouter, IdempotencyLog, SignatureVerifier}

  @type handle_opts :: [verifier: module(), secret: String.t()]

  @doc """
  Verifies, deduplicates, and processes an inbound Stripe webhook payload.

  Returns `:ok` for successful or already-processed events,
  or `{:error, reason}` for verification failures and processing errors.
  """
  @spec handle(String.t(), String.t(), String.t(), handle_opts()) ::
          :ok | {:error, String.t()}
  def handle(raw_payload, signature_header, event_id, opts \\ [])
      when is_binary(raw_payload) and is_binary(signature_header) and is_binary(event_id) do
    verifier = Keyword.get(opts, :verifier, SignatureVerifier)
    secret = Keyword.fetch!(opts, :secret)

    with :ok <- verifier.verify(raw_payload, signature_header, secret),
         :not_seen <- IdempotencyLog.check(event_id),
         {:ok, event} <- decode_event(raw_payload),
         :ok <- EventRouter.dispatch(event) do
      IdempotencyLog.record(event_id)
      :ok
    else
      :already_processed -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_event(raw) do
    case Jason.decode(raw) do
      {:ok, %{"type" => type, "data" => data, "id" => id}} ->
        {:ok, %{type: type, data: data, id: id}}

      {:ok, _} ->
        {:error, "webhook payload missing required fields"}

      {:error, _} ->
        {:error, "invalid JSON payload"}
    end
  end
end

defmodule Billing.WebhookHandler.EventRouter do
  @moduledoc "Routes decoded Stripe events to domain handlers by event type."

  @type event :: %{type: String.t(), data: map(), id: String.t()}

  @doc """
  Dispatches an event to its registered handler.
  """
  @spec dispatch(event()) :: :ok | {:error, String.t()}
  def dispatch(%{type: "payment_intent.succeeded"} = event) do
    Billing.Handlers.PaymentSucceeded.handle(event.data)
  end

  def dispatch(%{type: "payment_intent.payment_failed"} = event) do
    Billing.Handlers.PaymentFailed.handle(event.data)
  end

  def dispatch(%{type: "customer.subscription.deleted"} = event) do
    Billing.Handlers.SubscriptionCancelled.handle(event.data)
  end

  def dispatch(%{type: "invoice.payment_succeeded"} = event) do
    Billing.Handlers.InvoicePaid.handle(event.data)
  end

  def dispatch(%{type: type}) do
    require Logger
    Logger.debug("unhandled Stripe event type: #{type}")
    :ok
  end
end

defmodule Billing.WebhookHandler.IdempotencyLog do
  @moduledoc "Tracks processed webhook event IDs to prevent duplicate handling."

  use Agent

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  @spec check(String.t()) :: :not_seen | :already_processed
  def check(event_id) when is_binary(event_id) do
    if Agent.get(__MODULE__, &MapSet.member?(&1, event_id)) do
      :already_processed
    else
      :not_seen
    end
  end

  @spec record(String.t()) :: :ok
  def record(event_id) when is_binary(event_id) do
    Agent.update(__MODULE__, &MapSet.put(&1, event_id))
  end
end

defmodule Billing.WebhookHandler.SignatureVerifier do
  @moduledoc "Verifies Stripe webhook HMAC signatures."

  @tolerance_seconds 300

  @spec verify(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def verify(payload, signature_header, secret)
      when is_binary(payload) and is_binary(signature_header) and is_binary(secret) do
    with {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- check_timestamp_tolerance(timestamp),
         :ok <- verify_signature(payload, timestamp, secret, signatures) do
      :ok
    end
  end

  defp parse_signature_header(header) do
    parts = String.split(header, ",")
    timestamp = find_part(parts, "t=")
    signatures = parts |> Enum.filter(&String.starts_with?(&1, "v1=")) |> Enum.map(&String.replace_prefix(&1, "v1=", ""))

    if is_binary(timestamp) and signatures != [] do
      case Integer.parse(timestamp) do
        {ts, ""} -> {:ok, ts, signatures}
        _ -> {:error, "invalid timestamp in signature header"}
      end
    else
      {:error, "malformed signature header"}
    end
  end

  defp find_part(parts, prefix) do
    Enum.find_value(parts, fn p ->
      if String.starts_with?(p, prefix), do: String.replace_prefix(p, prefix, "")
    end)
  end

  defp check_timestamp_tolerance(timestamp) do
    diff = abs(System.system_time(:second) - timestamp)
    if diff <= @tolerance_seconds, do: :ok, else: {:error, "webhook timestamp too old"}
  end

  defp verify_signature(payload, timestamp, secret, signatures) do
    expected = compute_hmac(secret, "#{timestamp}.#{payload}")

    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)) do
      :ok
    else
      {:error, "signature mismatch"}
    end
  end

  defp compute_hmac(secret, data) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
  end
end
```
