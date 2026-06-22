```elixir
defmodule Infra.ServiceMesh.HealthRegistry do
  @moduledoc """
  Maintains a registry of service instance health states within a mesh.
  Instances register themselves with a heartbeat; the registry marks them
  unhealthy when heartbeats are overdue. Health consumers query the registry
  for routing decisions without coupling to individual instances.
  """

  use GenServer

  @default_heartbeat_ttl_ms 15_000
  @sweep_interval_ms 5_000

  @type instance_id :: String.t()
  @type service_name :: String.t()
  @type health_status :: :healthy | :unhealthy | :unknown
  @type instance :: %{
          id: instance_id(),
          service: service_name(),
          address: String.t(),
          port: pos_integer(),
          status: health_status(),
          last_heartbeat_at: integer()
        }
  @type state :: %{instances: %{instance_id() => instance()}, heartbeat_ttl_ms: pos_integer()}

  @doc """
  Starts the HealthRegistry linked to the calling process.

  ## Options
    - `:heartbeat_ttl_ms` - milliseconds before an instance is marked unhealthy (default: 15_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a service instance. Re-registration updates address and port.
  """
  @spec register(instance_id(), service_name(), String.t(), pos_integer()) :: :ok | {:error, String.t()}
  def register(instance_id, service, address, port)
      when is_binary(instance_id) and is_binary(service) and
             is_binary(address) and is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:register, instance_id, service, address, port})
  end

  def register(_id, _service, _address, _port), do: {:error, "invalid instance registration parameters"}

  @doc """
  Records a heartbeat for `instance_id`, restoring it to healthy status.
  """
  @spec heartbeat(instance_id()) :: :ok | {:error, :not_found}
  def heartbeat(instance_id) when is_binary(instance_id) do
    GenServer.call(__MODULE__, {:heartbeat, instance_id})
  end

  @doc """
  Returns all healthy instances for `service_name`.
  """
  @spec healthy_instances(service_name()) :: [instance()]
  def healthy_instances(service_name) when is_binary(service_name) do
    GenServer.call(__MODULE__, {:healthy_instances, service_name})
  end

  @doc """
  Returns the health status of a specific instance.
  """
  @spec status(instance_id()) :: {:ok, health_status()} | {:error, :not_found}
  def status(instance_id) when is_binary(instance_id) do
    GenServer.call(__MODULE__, {:status, instance_id})
  end

  @impl GenServer
  def init(opts) do
    ttl = Keyword.get(opts, :heartbeat_ttl_ms, @default_heartbeat_ttl_ms)
    schedule_sweep()
    {:ok, %{instances: %{}, heartbeat_ttl_ms: ttl}}
  end

  @impl GenServer
  def handle_call({:register, id, service, address, port}, _from, state) do
    instance = %{
      id: id,
      service: service,
      address: address,
      port: port,
      status: :healthy,
      last_heartbeat_at: now_ms()
    }

    {:reply, :ok, %{state | instances: Map.put(state.instances, id, instance)}}
  end

  @impl GenServer
  def handle_call({:heartbeat, id}, _from, state) do
    case Map.fetch(state.instances, id) do
      {:ok, instance} ->
        updated = %{instance | status: :healthy, last_heartbeat_at: now_ms()}
        {:reply, :ok, %{state | instances: Map.put(state.instances, id, updated)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:healthy_instances, service}, _from, state) do
    results =
      state.instances
      |> Map.values()
      |> Enum.filter(fn i -> i.service == service and i.status == :healthy end)

    {:reply, results, state}
  end

  @impl GenServer
  def handle_call({:status, id}, _from, state) do
    case Map.fetch(state.instances, id) do
      {:ok, instance} -> {:reply, {:ok, instance.status}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.heartbeat_ttl_ms

    updated_instances =
      Map.new(state.instances, fn {id, instance} ->
        if instance.last_heartbeat_at < cutoff and instance.status == :healthy do
          {id, %{instance | status: :unhealthy}}
        else
          {id, instance}
        end
      end)

    schedule_sweep()
    {:noreply, %{state | instances: updated_instances}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
