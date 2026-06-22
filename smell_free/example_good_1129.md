```elixir
defmodule Webhooks.DeliverySupervisor do
  @moduledoc """
  Top-level supervisor for the webhook delivery subsystem.
  Manages the delivery queue worker and its supporting registry.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Webhooks.DeliveryRegistry},
      {DynamicSupervisor, name: Webhooks.DeliveryWorkerSupervisor, strategy: :one_for_one},
      Webhooks.DeliveryDispatcher
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule Webhooks.DeliveryDispatcher do
  @moduledoc """
  Receives delivery requests and spawns isolated worker processes
  under the dynamic supervisor. Prevents duplicate deliveries for
  the same delivery ID using the registry.
  """

  use GenServer

  alias Webhooks.DeliveryWorker

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec dispatch(String.t(), String.t(), map(), keyword()) :: :ok | {:error, :already_dispatched}
  def dispatch(delivery_id, endpoint_url, payload, opts \\ [])
      when is_binary(delivery_id) and is_binary(endpoint_url) and is_map(payload) do
    GenServer.call(__MODULE__, {:dispatch, delivery_id, endpoint_url, payload, opts})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:dispatch, delivery_id, url, payload, opts}, _from, state) do
    case Registry.lookup(Webhooks.DeliveryRegistry, delivery_id) do
      [_existing] ->
        {:reply, {:error, :already_dispatched}, state}

      [] ->
        spec = {DeliveryWorker, delivery_id: delivery_id, url: url, payload: payload, opts: opts}
        DynamicSupervisor.start_child(Webhooks.DeliveryWorkerSupervisor, spec)
        {:reply, :ok, state}
    end
  end
end

defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  Isolated GenServer that performs a single webhook HTTP delivery
  with exponential backoff retry logic. Terminates itself after
  final success or exhaustion of retry attempts.
  """

  use GenServer, restart: :temporary

  alias Webhooks.HttpClient

  @max_attempts 5
  @base_delay_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    delivery_id = Keyword.fetch!(opts, :delivery_id)
    name = {:via, Registry, {Webhooks.DeliveryRegistry, delivery_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      delivery_id: Keyword.fetch!(opts, :delivery_id),
      url: Keyword.fetch!(opts, :url),
      payload: Keyword.fetch!(opts, :payload),
      attempt: 1,
      max_attempts: Keyword.get(opts, :max_attempts, @max_attempts)
    }

    send(self(), :deliver)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:deliver, state) do
    case HttpClient.post(state.url, state.payload) do
      {:ok, status} when status in 200..299 ->
        emit_success(state)
        {:stop, :normal, state}

      {:ok, status} ->
        handle_failure(state, "HTTP #{status}")

      {:error, reason} ->
        handle_failure(state, inspect(reason))
    end
  end

  @spec handle_failure(map(), String.t()) :: {:noreply, map()} | {:stop, :normal, map()}
  defp handle_failure(%{attempt: attempt, max_attempts: max} = state, reason)
       when attempt >= max do
    emit_exhausted(state, reason)
    {:stop, :normal, state}
  end

  defp handle_failure(state, reason) do
    delay = @base_delay_ms * :math.pow(2, state.attempt - 1) |> round()
    emit_retry(state, reason, delay)
    Process.send_after(self(), :deliver, delay)
    {:noreply, %{state | attempt: state.attempt + 1}}
  end

  defp emit_success(state) do
    :telemetry.execute(
      [:webhooks, :delivery, :success],
      %{attempt: state.attempt},
      %{delivery_id: state.delivery_id, url: state.url}
    )
  end

  defp emit_retry(state, reason, delay_ms) do
    :telemetry.execute(
      [:webhooks, :delivery, :retry],
      %{attempt: state.attempt, delay_ms: delay_ms},
      %{delivery_id: state.delivery_id, url: state.url, reason: reason}
    )
  end

  defp emit_exhausted(state, reason) do
    :telemetry.execute(
      [:webhooks, :delivery, :exhausted],
      %{attempts: state.attempt},
      %{delivery_id: state.delivery_id, url: state.url, last_reason: reason}
    )
  end
end
```
