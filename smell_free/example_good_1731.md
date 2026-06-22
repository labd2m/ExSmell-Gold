**File:** `example_good_1731.md`

```elixir
defmodule Webhooks.DispatchSupervisor do
  @moduledoc """
  Supervises the webhook dispatcher and its associated task supervisor.
  Both children are restarted together on failure to preserve consistency.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Webhooks.TaskSupervisor},
      {Webhooks.Dispatcher, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Webhooks.Delivery do
  @moduledoc "Represents a single webhook delivery attempt and its outcome."

  @enforce_keys [:id, :endpoint_url, :payload, :event_type]
  defstruct [
    :id,
    :endpoint_url,
    :payload,
    :event_type,
    attempts: 0,
    last_error: nil,
    status: :pending
  ]

  @type status :: :pending | :delivered | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          endpoint_url: String.t(),
          payload: map(),
          event_type: String.t(),
          attempts: non_neg_integer(),
          last_error: String.t() | nil,
          status: status()
        }
end

defmodule Webhooks.Dispatcher do
  @moduledoc """
  A GenServer that queues and dispatches webhook deliveries with
  exponential backoff retry logic. Each delivery runs in a supervised Task.
  """

  use GenServer

  require Logger

  alias Webhooks.{Delivery, HttpClient}

  @max_attempts 5
  @base_backoff_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(Delivery.t()) :: :ok
  def enqueue(%Delivery{} = delivery) do
    GenServer.cast(__MODULE__, {:enqueue, delivery})
  end

  @spec pending_count() :: non_neg_integer()
  def pending_count do
    GenServer.call(__MODULE__, :pending_count)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{queue: :queue.new()}}
  end

  @impl GenServer
  def handle_cast({:enqueue, delivery}, %{queue: queue} = state) do
    dispatch_async(delivery)
    {:noreply, %{state | queue: :queue.in(delivery, queue)}}
  end

  @impl GenServer
  def handle_call(:pending_count, _from, %{queue: queue} = state) do
    {:reply, :queue.len(queue), state}
  end

  @impl GenServer
  def handle_info({:retry, delivery}, state) do
    dispatch_async(delivery)
    {:noreply, state}
  end

  defp dispatch_async(%Delivery{} = delivery) do
    Task.Supervisor.start_child(Webhooks.TaskSupervisor, fn ->
      attempt_delivery(delivery)
    end)
  end

  defp attempt_delivery(%Delivery{attempts: n} = delivery) when n >= @max_attempts do
    Logger.error("Webhook #{delivery.id} exhausted #{@max_attempts} attempts. Giving up.")
  end

  defp attempt_delivery(%Delivery{} = delivery) do
    case HttpClient.post(delivery.endpoint_url, delivery.payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Webhook #{delivery.id} delivered on attempt #{delivery.attempts + 1}")

      {:ok, %{status: status}} ->
        Logger.warning("Webhook #{delivery.id} got non-2xx status #{status}, scheduling retry")
        schedule_retry(%{delivery | attempts: delivery.attempts + 1, last_error: "HTTP #{status}"})

      {:error, reason} ->
        Logger.warning("Webhook #{delivery.id} network error: #{inspect(reason)}, scheduling retry")
        schedule_retry(%{delivery | attempts: delivery.attempts + 1, last_error: inspect(reason)})
    end
  end

  defp schedule_retry(%Delivery{attempts: n} = delivery) do
    delay = @base_backoff_ms * round(:math.pow(2, n - 1))
    Process.send_after(self(), {:retry, delivery}, delay)
  end
end
```
