```elixir
defmodule Platform.CacheWarmer do
  @moduledoc """
  A GenServer that proactively warms a set of registered cache loaders
  on startup and on a configurable refresh schedule.

  Each loader is a named function that fetches data from the source of
  truth and populates the cache. Loaders run concurrently under a
  Task.Supervisor and failures in one loader do not affect others.
  """

  use GenServer

  require Logger

  alias Platform.Cache

  @type loader_name :: atom()
  @type loader_fn :: (-> {:ok, [{term(), term()}]} | {:error, term()})
  @type loader_spec :: %{name: loader_name(), fun: loader_fn(), ttl_ms: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a named cache loader. The `fun` must return `{:ok, [{key, value}]}`
  or `{:error, reason}`. Each key-value pair is stored with `ttl_ms`.
  """
  @spec register(loader_name(), loader_fn(), pos_integer()) :: :ok
  def register(name, fun, ttl_ms)
      when is_atom(name) and is_function(fun, 0) and is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.cast(__MODULE__, {:register, name, fun, ttl_ms})
  end

  @doc "Triggers an immediate warm cycle for all registered loaders."
  @spec warm_now() :: :ok
  def warm_now, do: GenServer.cast(__MODULE__, :warm_all)

  @doc "Returns the names of all currently registered loaders."
  @spec registered_loaders() :: [loader_name()]
  def registered_loaders, do: GenServer.call(__MODULE__, :loaders)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :refresh_interval_ms, :timer.minutes(5))
    task_sup = Keyword.get(opts, :task_supervisor, Platform.CacheWarmer.TaskSupervisor)
    send(self(), :warm_all)
    {:ok, %{loaders: %{}, interval: interval, task_sup: task_sup}}
  end

  @impl GenServer
  def handle_cast({:register, name, fun, ttl_ms}, state) do
    spec = %{name: name, fun: fun, ttl_ms: ttl_ms}
    new_state = put_in(state, [:loaders, name], spec)
    Task.Supervisor.start_child(state.task_sup, fn -> run_loader(spec) end)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast(:warm_all, state) do
    warm_all_loaders(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:loaders, _from, state) do
    {:reply, Map.keys(state.loaders), state}
  end

  @impl GenServer
  def handle_info(:warm_all, %{interval: interval} = state) do
    warm_all_loaders(state)
    Process.send_after(self(), :warm_all, interval)
    {:noreply, state}
  end

  defp warm_all_loaders(%{loaders: loaders, task_sup: task_sup}) do
    loaders
    |> Map.values()
    |> Task.Supervisor.async_stream_nolink(task_sup, &run_loader/1,
      max_concurrency: map_size(loaders),
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp run_loader(%{name: name, fun: fun, ttl_ms: ttl_ms}) do
    case fun.() do
      {:ok, entries} when is_list(entries) ->
        Enum.each(entries, fn {key, value} -> Cache.put(key, value, ttl_ms) end)
        Logger.info("[CacheWarmer] Loader complete", loader: name, entries: length(entries))

      {:error, reason} ->
        Logger.error("[CacheWarmer] Loader failed", loader: name, reason: inspect(reason))
    end
  end
end
```
