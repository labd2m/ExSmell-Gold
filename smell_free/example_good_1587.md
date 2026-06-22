```elixir
defmodule Webhooks.Dispatcher do
  @moduledoc """
  Dispatches outbound webhook payloads to registered endpoint URLs.

  Each delivery attempt is executed in a supervised Task. Failed deliveries
  are retried with exponential backoff up to a configurable maximum.
  """

  use GenServer

  require Logger

  alias Webhooks.{DeliveryLog, EndpointRegistry, HttpSender}

  @max_attempts 5
  @base_backoff_ms 1_000

  @type delivery_request :: %{
          endpoint_id: String.t(),
          event_type: String.t(),
          payload: map()
        }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Enqueues a webhook delivery for asynchronous dispatch.
  """
  @spec enqueue(delivery_request()) :: :ok | {:error, String.t()}
  def enqueue(%{endpoint_id: eid, event_type: et, payload: p} = req)
      when is_binary(eid) and is_binary(et) and is_map(p) do
    GenServer.cast(__MODULE__, {:enqueue, req})
  end

  def enqueue(_), do: {:error, "invalid delivery request"}

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:enqueue, request}, state) do
    attempt_delivery(request, 1)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:retry, request, attempt}, state) do
    attempt_delivery(request, attempt)
    {:noreply, state}
  end

  defp attempt_delivery(request, attempt) do
    Task.Supervisor.start_child(Webhooks.TaskSupervisor, fn ->
      deliver(request, attempt)
    end)
  end

  defp deliver(request, attempt) do
    with {:ok, endpoint} <- EndpointRegistry.fetch(request.endpoint_id),
         {:ok, _response} <- HttpSender.post(endpoint.url, request.payload, endpoint.secret) do
      DeliveryLog.record_success(request, attempt)
      Logger.debug("webhook delivered to #{endpoint.url} on attempt #{attempt}")
    else
      {:error, reason} ->
        DeliveryLog.record_failure(request, attempt, reason)
        schedule_retry_or_abandon(request, attempt, reason)
    end
  end

  defp schedule_retry_or_abandon(request, attempt, reason) when attempt < @max_attempts do
    backoff = @base_backoff_ms * :math.pow(2, attempt - 1) |> round()
    Logger.warning("webhook delivery failed (attempt #{attempt}/#{@max_attempts}): #{reason}")
    Process.send_after(self(), {:retry, request, attempt + 1}, backoff)
  end

  defp schedule_retry_or_abandon(request, attempt, reason) do
    Logger.error(
      "webhook permanently failed after #{attempt} attempts for endpoint #{request.endpoint_id}: #{reason}"
    )

    DeliveryLog.record_permanent_failure(request, reason)
  end
end
```
