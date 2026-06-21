```elixir
defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  A transient GenServer that delivers a webhook payload to an endpoint URL
  with configurable exponential-backoff retry logic.

  Each delivery attempt is individually logged. The worker stops normally
  on successful delivery and with a shutdown reason after exhausting all
  retry attempts, ensuring the supervisor can record the final outcome.
  """

  use GenServer, restart: :transient

  require Logger

  alias Webhooks.DeliveryRecord

  @type delivery_id :: pos_integer()
  @type state :: %{
          delivery: DeliveryRecord.t(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer()
        }

  @default_max_attempts 5
  @default_base_delay_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      delivery: Keyword.fetch!(opts, :delivery),
      attempt: 0,
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_delay_ms: Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    }

    {:ok, state, {:continue, :deliver}}
  end

  @impl GenServer
  def handle_continue(:deliver, state) do
    attempt_delivery(state)
  end

  @impl GenServer
  def handle_info(:retry, state) do
    attempt_delivery(state)
  end

  defp attempt_delivery(%{delivery: delivery, attempt: attempt, max_attempts: max} = state) do
    new_state = %{state | attempt: attempt + 1}

    case send_request(delivery) do
      {:ok, status} when status in 200..299 ->
        Logger.info("[DeliveryWorker] Delivered", id: delivery.id, attempt: new_state.attempt, status: status)
        mark_delivered(delivery)
        {:stop, :normal, new_state}

      {:ok, status} ->
        handle_failure(new_state, {:http_error, status})

      {:error, reason} ->
        handle_failure(new_state, reason)
    end
  end

  defp handle_failure(%{attempt: attempt, max_attempts: max} = state, reason)
       when attempt >= max do
    Logger.error("[DeliveryWorker] Exhausted retries", id: state.delivery.id, reason: inspect(reason))
    mark_failed(state.delivery, reason)
    {:stop, {:shutdown, :max_retries_exceeded}, state}
  end

  defp handle_failure(%{attempt: attempt, base_delay_ms: base} = state, reason) do
    delay = backoff_delay(attempt, base)
    Logger.warning("[DeliveryWorker] Attempt failed, retrying", id: state.delivery.id, attempt: attempt, delay_ms: delay, reason: inspect(reason))
    Process.send_after(self(), :retry, delay)
    {:noreply, state}
  end

  defp send_request(%DeliveryRecord{endpoint_url: url, payload: payload, secret: secret}) do
    headers = [
      {"content-type", "application/json"},
      {"x-signature-256", sign(payload, secret)}
    ]

    case Req.post(url, body: Jason.encode!(payload), headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  end

  defp sign(payload, secret) do
    mac = :crypto.mac(:hmac, :sha256, secret, Jason.encode!(payload))
    "sha256=" <> Base.encode16(mac, case: :lower)
  end

  defp backoff_delay(attempt, base_ms) do
    jitter = :rand.uniform(500)
    trunc(:math.pow(2, attempt) * base_ms) + jitter
  end

  defp mark_delivered(delivery) do
    DeliveryRecord.mark_delivered_changeset(delivery)
    |> Webhooks.Repo.update()
  end

  defp mark_failed(delivery, reason) do
    DeliveryRecord.mark_failed_changeset(delivery, inspect(reason))
    |> Webhooks.Repo.update()
  end
end
```
