```elixir
defmodule CacheWarmer.Loader do
  @moduledoc """
  Behaviour for a single cache warming routine.

  Each loader declares a name and implements `warm/1`, which receives
  the cache module and populates it. Returning `{:ok, count}` reports
  how many entries were loaded; `{:error, reason}` is logged and the
  warm-up continues with remaining loaders.
  """

  @callback name() :: atom()
  @callback warm(cache :: module()) :: {:ok, non_neg_integer()} | {:error, term()}
end

defmodule CacheWarmer.Supervisor do
  @moduledoc """
  Orchestrates parallel cache warm-up on application startup.

  Each registered loader runs in a supervised Task. Warm-up is
  non-blocking: the supervisor starts the tasks and the application
  continues initialising. A `warm_all/2` call can be used from
  `Application.start/2` when a fully warm cache is required before
  accepting traffic.
  """

  use Supervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec warm_all([module()], module(), pos_integer()) ::
          %{succeeded: [atom()], failed: [atom()]}
  def warm_all(loader_modules, cache, timeout_ms \\ 30_000)
      when is_list(loader_modules) and is_atom(cache) do
    loader_modules
    |> Task.async_stream(
      fn loader_module ->
        name = loader_module.name()
        start = System.monotonic_time(:millisecond)

        result =
          case loader_module.warm(cache) do
            {:ok, count} ->
              duration = System.monotonic_time(:millisecond) - start
              Logger.info("Cache warm-up complete", loader: name, entries: count, duration_ms: duration)
              {:ok, name}

            {:error, reason} ->
              Logger.error("Cache warm-up failed", loader: name, reason: inspect(reason))
              {:error, name}
          end

        result
      end,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{succeeded: [], failed: []}, fn
      {:ok, {:ok, name}}, acc -> %{acc | succeeded: [name | acc.succeeded]}
      {:ok, {:error, name}}, acc -> %{acc | failed: [name | acc.failed]}
      {:exit, reason}, acc ->
        Logger.error("Cache warm-up task crashed", reason: inspect(reason))
        acc
    end)
  end

  @spec warm_async([module()], module()) :: :ok
  def warm_async(loader_modules, cache) when is_list(loader_modules) and is_atom(cache) do
    Enum.each(loader_modules, fn loader_module ->
      Task.Supervisor.start_child(CacheWarmer.TaskSupervisor, fn ->
        case loader_module.warm(cache) do
          {:ok, count} ->
            Logger.info("Async cache warm-up done", loader: loader_module.name(), entries: count)

          {:error, reason} ->
            Logger.warning("Async cache warm-up failed",
              loader: loader_module.name(),
              reason: inspect(reason)
            )
        end
      end)
    end)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Task.Supervisor, name: CacheWarmer.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule CacheWarmer.Loaders.FeatureFlags do
  @moduledoc false

  @behaviour CacheWarmer.Loader

  @impl CacheWarmer.Loader
  def name, do: :feature_flags

  @impl CacheWarmer.Loader
  def warm(cache) when is_atom(cache) do
    flags = MyApp.Repo.all(FeatureFlags.Flag)

    Enum.each(flags, fn flag ->
      cache.set(flag.name, flag.value)
    end)

    {:ok, length(flags)}
  rescue
    error -> {:error, error}
  end
end
```
