```elixir
defmodule MyApp.Platform.ServiceMesh do
  @moduledoc """
  A lightweight service mesh registry that tracks named internal service
  endpoints and provides client-side load balancing across multiple
  instances. Endpoints register themselves on startup and deregister on
  shutdown. Health checks are performed periodically; unhealthy endpoints
  are removed from rotation until they recover.

  All load-balancing decisions are made locally without a central
  coordinator, making the mesh resilient to partial failures.
  """

  use GenServer

  require Logger

  @health_check_interval_ms 15_000
  @health_timeout_ms 3_000

  @type service_name :: atom()
  @type endpoint :: %{id: String.t(), url: String.t(), healthy: boolean()}

  @doc "Starts the service mesh registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers an endpoint for `service_name`."
  @spec register(service_name(), String.t()) :: {:ok, String.t()}
  def register(service_name, url) when is_atom(service_name) and is_binary(url) do
    id = endpoint_id(service_name, url)
    GenServer.call(__MODULE__, {:register, service_name, id, url})
    {:ok, id}
  end

  @doc "Deregisters the endpoint with `endpoint_id` from `service_name`."
  @spec deregister(service_name(), String.t()) :: :ok
  def deregister(service_name, endpoint_id) when is_atom(service_name) do
    GenServer.cast(__MODULE__, {:deregister, service_name, endpoint_id})
  end

  @doc """
  Returns a healthy endpoint URL for `service_name` using round-robin
  selection, or `{:error, :no_healthy_endpoints}`.
  """
  @spec resolve(service_name()) :: {:ok, String.t()} | {:error, :no_healthy_endpoints}
  def resolve(service_name) when is_atom(service_name) do
    GenServer.call(__MODULE__, {:resolve, service_name})
  end

  @doc "Returns all registered endpoints for `service_name`."
  @spec endpoints(service_name()) :: [endpoint()]
  def endpoints(service_name) when is_atom(service_name) do
    GenServer.call(__MODULE__, {:endpoints, service_name})
  end

  @impl GenServer
  def init(_opts) do
    schedule_health_checks()
    {:ok, %{services: %{}, cursors: %{}}}
  end

  @impl GenServer
  def handle_call({:register, service, id, url}, _from, state) do
    endpoint = %{id: id, url: url, healthy: true}
    updated = Map.update(state.services, service, [endpoint], &update_or_add(&1, endpoint))
    {:reply, :ok, %{state | services: updated}}
  end

  @impl GenServer
  def handle_call({:resolve, service}, _from, state) do
    healthy = state.services |> Map.get(service, []) |> Enum.filter(& &1.healthy)

    case healthy do
      [] ->
        {:reply, {:error, :no_healthy_endpoints}, state}

      endpoints ->
        cursor = Map.get(state.cursors, service, 0)
        chosen = Enum.at(endpoints, rem(cursor, length(endpoints)))
        new_cursors = Map.put(state.cursors, service, cursor + 1)
        {:reply, {:ok, chosen.url}, %{state | cursors: new_cursors}}
    end
  end

  @impl GenServer
  def handle_call({:endpoints, service}, _from, state) do
    {:reply, Map.get(state.services, service, []), state}
  end

  @impl GenServer
  def handle_cast({:deregister, service, id}, state) do
    updated = Map.update(state.services, service, [], &Enum.reject(&1, fn e -> e.id == id end))
    {:noreply, %{state | services: updated}}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    updated_services =
      Map.new(state.services, fn {service, endpoints} ->
        checked = Enum.map(endpoints, &check_endpoint_health/1)
        {service, checked}
      end)

    schedule_health_checks()
    {:noreply, %{state | services: updated_services}}
  end

  @spec check_endpoint_health(endpoint()) :: endpoint()
  defp check_endpoint_health(endpoint) do
    healthy =
      case :httpc.request(:get, {String.to_charlist("#{endpoint.url}/health"), []},
             [{:timeout, @health_timeout_ms}], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> true
        _ -> false
      end

    unless healthy == endpoint.healthy do
      Logger.info("service_mesh_endpoint_health_changed",
        id: endpoint.id,
        healthy: healthy
      )
    end

    %{endpoint | healthy: healthy}
  end

  @spec update_or_add([endpoint()], endpoint()) :: [endpoint()]
  defp update_or_add(endpoints, new_endpoint) do
    if Enum.any?(endpoints, &(&1.id == new_endpoint.id)) do
      Enum.map(endpoints, fn e -> if e.id == new_endpoint.id, do: new_endpoint, else: e end)
    else
      [new_endpoint | endpoints]
    end
  end

  @spec endpoint_id(service_name(), String.t()) :: String.t()
  defp endpoint_id(service, url) do
    "#{service}:#{:crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)}"
  end

  @spec schedule_health_checks() :: reference()
  defp schedule_health_checks,
    do: Process.send_after(self(), :health_check, @health_check_interval_ms)
end
```
