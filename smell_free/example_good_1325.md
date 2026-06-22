```elixir
defmodule Routing.FailoverRouter do
  @moduledoc """
  Routes requests across a priority-ordered list of regional endpoints,
  failing over to the next available region on error or timeout.

  Health state is maintained per-region and updated after each request.
  Unhealthy regions are skipped and retried after a cooldown period.
  """

  use GenServer

  require Logger

  alias Routing.FailoverRouter.{RegionHealth, Request, Response, Dispatcher}

  @cooldown_ms 30_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Routes a request through the healthy region list in priority order.

  Returns `{:ok, response}` from the first region that succeeds, or
  `{:error, :all_regions_failed}` if every region returns an error.
  """
  @spec route(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, :all_regions_failed}
  def route(%Request{} = request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    GenServer.call(__MODULE__, {:route, request, timeout})
  end

  @doc """
  Returns the current health status for all configured regions.
  """
  @spec health_status() :: %{String.t() => RegionHealth.status()}
  def health_status, do: GenServer.call(__MODULE__, :health_status)

  @impl GenServer
  def init(opts) do
    regions = Keyword.fetch!(opts, :regions)
    dispatcher = Keyword.get(opts, :dispatcher, Dispatcher.default())

    health =
      Map.new(regions, fn %{id: id} = region ->
        {id, RegionHealth.new(region)}
      end)

    priority_order = Enum.map(regions, & &1.id)
    {:ok, %{health: health, priority_order: priority_order, dispatcher: dispatcher}}
  end

  @impl GenServer
  def handle_call({:route, request, timeout}, _from, state) do
    healthy_regions = select_healthy(state)
    {result, updated_health} = try_regions(healthy_regions, request, timeout, state.dispatcher, state.health)
    {:reply, result, %{state | health: updated_health}}
  end

  def handle_call(:health_status, _from, state) do
    statuses = Map.new(state.health, fn {id, h} -> {id, RegionHealth.status(h)} end)
    {:reply, statuses, state}
  end

  @impl GenServer
  def handle_info({:unmark_unhealthy, region_id}, state) do
    updated = Map.update!(state.health, region_id, &RegionHealth.mark_healthy/1)
    Logger.info("region #{region_id} re-enabled after cooldown")
    {:noreply, %{state | health: updated}}
  end

  defp select_healthy(%{priority_order: order, health: health}) do
    Enum.filter(order, fn id ->
      health |> Map.get(id) |> RegionHealth.healthy?()
    end)
  end

  defp try_regions([], _request, _timeout, _dispatcher, health) do
    {{:error, :all_regions_failed}, health}
  end

  defp try_regions([region_id | rest], request, timeout, dispatcher, health) do
    region = get_in(health, [region_id, :config])

    case Dispatcher.dispatch(dispatcher, region, request, timeout) do
      {:ok, response} ->
        updated = Map.update!(health, region_id, &RegionHealth.record_success/1)
        {{:ok, response}, updated}

      {:error, reason} ->
        Logger.warning("region #{region_id} failed: #{reason}")
        updated = Map.update!(health, region_id, &RegionHealth.mark_unhealthy/1)
        schedule_cooldown(region_id)
        try_regions(rest, request, timeout, dispatcher, updated)
    end
  end

  defp schedule_cooldown(region_id) do
    Process.send_after(self(), {:unmark_unhealthy, region_id}, @cooldown_ms)
  end
end

defmodule Routing.FailoverRouter.RegionHealth do
  @moduledoc false

  @enforce_keys [:config, :healthy, :failure_count]
  defstruct [:config, :healthy, :failure_count, :last_failure_at]

  @type status :: :healthy | :unhealthy
  @type t :: %__MODULE__{}

  @spec new(map()) :: t()
  def new(config), do: %__MODULE__{config: config, healthy: true, failure_count: 0}

  @spec healthy?(t()) :: boolean()
  def healthy?(%__MODULE__{healthy: h}), do: h

  @spec status(t()) :: status()
  def status(%__MODULE__{healthy: true}), do: :healthy
  def status(%__MODULE__{healthy: false}), do: :unhealthy

  @spec mark_healthy(t()) :: t()
  def mark_healthy(h), do: %{h | healthy: true}

  @spec mark_unhealthy(t()) :: t()
  def mark_unhealthy(h), do: %{h | healthy: false, last_failure_at: DateTime.utc_now()}

  @spec record_success(t()) :: t()
  def record_success(h), do: %{h | failure_count: 0}
end

defmodule Routing.FailoverRouter.Request do
  @moduledoc false

  @enforce_keys [:path, :method]
  defstruct [:path, :method, :body, :headers]

  @type t :: %__MODULE__{}
end

defmodule Routing.FailoverRouter.Response do
  @moduledoc false

  @enforce_keys [:status, :body, :region_id]
  defstruct [:status, :body, :region_id, :headers]

  @type t :: %__MODULE__{}
end

defmodule Routing.FailoverRouter.Dispatcher do
  @moduledoc "Behaviour for regional request dispatchers."

  @callback dispatch(map(), Routing.FailoverRouter.Request.t(), pos_integer()) ::
              {:ok, Routing.FailoverRouter.Response.t()} | {:error, String.t()}

  @spec dispatch(module(), map(), Routing.FailoverRouter.Request.t(), pos_integer()) ::
          {:ok, Routing.FailoverRouter.Response.t()} | {:error, String.t()}
  def dispatch(mod, region, request, timeout), do: mod.dispatch(region, request, timeout)

  @spec default() :: module()
  def default, do: Application.get_env(:routing, :dispatcher, Routing.FailoverRouter.HttpDispatcher)
end
```
