```elixir
# ── file: lib/webhooks/handler.ex ───────────────────────────────────────────


defmodule Webhooks.Handler do
  @moduledoc """
  Inbound webhook event processor: verification, routing, and retry logic.
  Defined in `lib/webhooks/handler.ex`.
  """

  alias Webhooks.{SignatureVerifier, EventRouter, DeadLetterQueue, WebhookStore}

  @max_retries 5
  @retry_backoff_base_ms 1_000

  @type webhook_event :: %{
    id: String.t(),
    source: String.t(),
    type: String.t(),
    payload: map(),
    received_at: DateTime.t(),
    attempts: non_neg_integer(),
    status: :pending | :processed | :failed | :dead
  }

  @doc """
  Process an inbound webhook payload from a given source.
  Verifies the signature, persists the event, and dispatches it.
  """
  @spec process(String.t(), map()) :: :ok | {:error, String.t()}
  def process(source, %{"type" => type, "payload" => payload} = raw) do
    signature = Map.get(raw, "signature")

    with :ok <- verify_signature(source, payload, signature),
         {:ok, event} <- persist_event(source, type, payload) do
      dispatch(source, event)
    end
  end

  def process(_source, raw) do
    {:error, "Malformed webhook body: missing 'type' or 'payload' fields. Got: #{inspect(raw)}"}
  end

  @doc "Verify an HMAC signature for a given source's shared secret."
  @spec verify_signature(String.t(), map(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def verify_signature(_source, _payload, nil) do
    {:error, "Missing webhook signature"}
  end

  def verify_signature(source, payload, signature) do
    case SignatureVerifier.verify(source, payload, signature) do
      :ok -> :ok
      :invalid -> {:error, "Invalid signature for source: #{source}"}
      {:error, reason} -> {:error, "Signature verification error: #{reason}"}
    end
  end

  @doc "Route a verified webhook event to the appropriate handler."
  @spec dispatch(String.t(), webhook_event()) :: :ok | {:error, String.t()}
  def dispatch(source, event) do
    case EventRouter.route(source, event.type) do
      {:ok, handler_mod} ->
        case handler_mod.handle(event) do
          :ok ->
            WebhookStore.update(event.id, %{status: :processed})

          {:error, reason} ->
            handle_failure(event, reason)
        end

      :no_route ->
        WebhookStore.update(event.id, %{status: :processed})
        :ok
    end
  end

  @doc "Retry all failed webhook events that are under the max retry limit."
  @spec retry_failed() :: {:ok, non_neg_integer()}
  def retry_failed do
    events =
      WebhookStore.all(status: :failed)
      |> Enum.filter(&(&1.attempts < @max_retries))

    Enum.each(events, fn event ->
      backoff = trunc(@retry_backoff_base_ms * :math.pow(2, event.attempts))
      Process.sleep(backoff)
      dispatch(event.source, event)
    end)

    {:ok, length(events)}
  end

  @doc "Move an event to the dead letter queue after exhausting retries."
  @spec dead_letter(webhook_event()) :: :ok
  def dead_letter(event) do
    DeadLetterQueue.push(event)
    WebhookStore.update(event.id, %{status: :dead})
    :ok
  end

  defp persist_event(source, type, payload) do
    event = %{
      id: generate_id(),
      source: source,
      type: type,
      payload: payload,
      received_at: DateTime.utc_now(),
      attempts: 0,
      status: :pending
    }

    WebhookStore.save(event)
  end

  defp handle_failure(%{attempts: a} = event, reason) when a + 1 >= @max_retries do
    WebhookStore.update(event.id, %{
      status: :failed,
      attempts: a + 1,
      last_error: inspect(reason)
    })

    dead_letter(%{event | attempts: a + 1})
    {:error, "Event #{event.id} moved to dead letter queue after #{a + 1} attempts"}
  end

  defp handle_failure(%{attempts: a} = event, reason) do
    WebhookStore.update(event.id, %{
      status: :failed,
      attempts: a + 1,
      last_error: inspect(reason)
    })

    {:error, "Event #{event.id} failed (attempt #{a + 1}): #{inspect(reason)}"}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/webhooks/handler_dashboard.ex ─────────────────────────────────────────────────────


defmodule Webhooks.Handler do
  @moduledoc """
  Operations dashboard helpers for monitoring webhook processing.
  """

  alias Webhooks.{WebhookStore, DeadLetterQueue}

  @doc "Return aggregate processing stats for the last N hours."
  @spec stats(pos_integer()) :: map()
  def stats(hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    events = WebhookStore.all(received_after: since)

    grouped = Enum.group_by(events, & &1.status)

    %{
      total: length(events),
      processed: length(Map.get(grouped, :processed, [])),
      failed: length(Map.get(grouped, :failed, [])),
      dead: length(Map.get(grouped, :dead, [])),
      pending: length(Map.get(grouped, :pending, [])),
      window_hours: hours
    }
  end

  @doc "Return the N most recent dead-lettered events for review."
  @spec recent_dead_letters(pos_integer()) :: [map()]
  def recent_dead_letters(limit \\ 20) do
    DeadLetterQueue.peek(limit)
  end

  @doc "Return webhook event counts broken down by source and type."
  @spec breakdown_by_source(pos_integer()) :: [map()]
  def breakdown_by_source(hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    WebhookStore.all(received_after: since)
    |> Enum.group_by(&{&1.source, &1.type})
    |> Enum.map(fn {{source, type}, events} ->
      %{source: source, type: type, count: length(events)}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end
end

```
