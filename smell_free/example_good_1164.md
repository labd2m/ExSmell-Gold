```elixir
defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  Supervised GenServer responsible for delivering webhook payloads to a
  single registered subscriber endpoint.

  Payloads are queued internally and processed sequentially. Transient
  HTTP failures trigger retries with exponential backoff up to a configurable
  maximum. After exhausting retries, the failure is recorded and the worker
  moves on to the next queued payload without crashing.

  Each worker is identified by its subscription ID and registered in the
  application's process registry for direct addressing.
  """
  use GenServer, restart: :permanent

  require Logger

  alias Webhooks.{Subscription, DeliveryLog, HttpSender}

  @type state :: %{
          subscription: Subscription.t(),
          queue: :queue.queue(),
          retry_count: non_neg_integer()
        }

  @max_retries 5
  @base_backoff_ms 500

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Starts the delivery worker for the given subscription."
  @spec start_link(Subscription.t()) :: GenServer.on_start()
  def start_link(%Subscription{} = subscription) do
    GenServer.start_link(__MODULE__, subscription, name: via(subscription.id))
  end

  @doc "Enqueues a payload for delivery to the subscription's endpoint."
  @spec enqueue(String.t(), map()) :: :ok
  def enqueue(subscription_id, payload)
      when is_binary(subscription_id) and is_map(payload) do
    GenServer.cast(via(subscription_id), {:enqueue, payload})
  end

  @doc "Returns the current number of payloads waiting in the delivery queue."
  @spec queue_depth(String.t()) :: non_neg_integer()
  def queue_depth(subscription_id) when is_binary(subscription_id) do
    GenServer.call(via(subscription_id), :queue_depth)
  end

  # ── Server callbacks ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(%Subscription{} = subscription) do
    {:ok, %{subscription: subscription, queue: :queue.new(), retry_count: 0}}
  end

  @impl GenServer
  def handle_cast({:enqueue, payload}, state) do
    new_queue = :queue.in(payload, state.queue)
    send(self(), :process_next)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl GenServer
  def handle_call(:queue_depth, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  @impl GenServer
  def handle_info(:process_next, state) do
    case :queue.out(state.queue) do
      {{:value, payload}, remaining} ->
        attempt_delivery(payload, %{state | queue: remaining})

      {:empty, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, payload}, state) do
    attempt_delivery(payload, state)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp attempt_delivery(payload, state) do
    case HttpSender.post(state.subscription.endpoint_url, payload) do
      {:ok, response} ->
        on_delivery_success(response, payload, state)

      {:error, reason} ->
        on_delivery_failure(reason, payload, state)
    end
  end

  defp on_delivery_success(response, _payload, state) do
    Logger.info("Webhook delivered",
      subscription_id: state.subscription.id,
      status: response.status
    )
    DeliveryLog.record_success(state.subscription.id, response.status)
    send(self(), :process_next)
    {:noreply, %{state | retry_count: 0}}
  end

  defp on_delivery_failure(reason, payload, %{retry_count: count} = state)
       when count < @max_retries do
    backoff = round(@base_backoff_ms * :math.pow(2, count))
    Logger.warning("Webhook delivery failed, scheduling retry",
      reason: inspect(reason),
      attempt: count + 1,
      backoff_ms: backoff
    )
    Process.send_after(self(), {:retry, payload}, backoff)
    {:noreply, %{state | retry_count: count + 1}}
  end

  defp on_delivery_failure(reason, payload, state) do
    Logger.error("Webhook delivery permanently failed",
      subscription_id: state.subscription.id,
      reason: inspect(reason)
    )
    DeliveryLog.record_failure(state.subscription.id, payload, reason)
    send(self(), :process_next)
    {:noreply, %{state | retry_count: 0}}
  end

  defp via(subscription_id) do
    {:via, Registry, {Webhooks.Registry, subscription_id}}
  end
end
```
