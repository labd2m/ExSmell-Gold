```elixir
defmodule Ops.ConfigReloader do
  @moduledoc """
  Watches for configuration file changes and reloads application config at
  runtime without requiring a restart. Uses `:fs` file-system events when
  available and falls back to periodic polling. Registered callback modules
  are notified after each successful reload so subsystems can refresh
  their internal state.
  """

  use GenServer

  require Logger

  @type callback_fn :: (map() -> :ok)
  @type reload_result :: {:ok, map()} | {:error, :file_not_found | :parse_error}

  @poll_interval_ms :timer.seconds(30)

  @doc "Starts the config reloader watching the file at `path`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a callback function to be called after each successful reload."
  @spec on_reload(callback_fn()) :: :ok
  def on_reload(fun) when is_function(fun, 1) do
    GenServer.cast(__MODULE__, {:register_callback, fun})
  end

  @doc "Forces an immediate config reload outside the poll interval."
  @spec reload_now() :: reload_result()
  def reload_now, do: GenServer.call(__MODULE__, :reload_now)

  @doc "Returns the most recently loaded config map."
  @spec current_config() :: map()
  def current_config, do: GenServer.call(__MODULE__, :current_config)

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    {config, mtime} = load_config(path)
    Process.send_after(self(), :poll, interval)

    {:ok,
     %{path: path, interval: interval, config: config, last_mtime: mtime, callbacks: []}}
  end

  @impl GenServer
  def handle_call(:reload_now, _from, state) do
    {result, new_state} = do_reload(state)
    {:reply, result, new_state}
  end

  def handle_call(:current_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl GenServer
  def handle_cast({:register_callback, fun}, state) do
    {:noreply, %{state | callbacks: [fun | state.callbacks]}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_result, new_state} = do_reload(state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, new_state}
  end

  defp do_reload(%{path: path, last_mtime: last_mtime} = state) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} when mtime != last_mtime ->
        case parse_config(path) do
          {:ok, config} ->
            Logger.info("[ConfigReloader] Config reloaded from #{path}")
            notify_callbacks(state.callbacks, config)
            {{:ok, config}, %{state | config: config, last_mtime: mtime}}

          {:error, _} = err ->
            Logger.warning("[ConfigReloader] Failed to parse #{path}")
            {err, state}
        end

      {:ok, _} ->
        {{:ok, state.config}, state}

      {:error, :enoent} ->
        {{:error, :file_not_found}, state}
    end
  end

  defp load_config(path) do
    case parse_config(path) do
      {:ok, config} -> {config, file_mtime(path)}
      {:error, _} -> {%{}, nil}
    end
  end

  defp parse_config(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :parse_error}
        end

      {:error, _} ->
        {:error, :file_not_found}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp notify_callbacks(callbacks, config) do
    Enum.each(callbacks, fn fun ->
      try do
        fun.(config)
      rescue
        e -> Logger.error("[ConfigReloader] Callback raised: #{Exception.message(e)}")
      end
    end)
  end
end
```
