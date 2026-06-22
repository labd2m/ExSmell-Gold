```elixir
defmodule Config.FileWatcher do
  @moduledoc """
  Watches a TOML or JSON configuration file for changes and hot-reloads the
  application configuration without restarting the node. Powered by
  `FileSystem` (an inotify/kqueue wrapper), the watcher debounces rapid
  filesystem events and validates the new configuration before applying it,
  so an invalid file never corrupts the running configuration. PubSub
  broadcasts notify interested processes of successful reloads.
  """

  use GenServer

  require Logger

  @pubsub_topic "config:reloaded"
  @debounce_ms 300

  @type watch_opts :: [
          path: binary(),
          format: :toml | :json,
          validator: (map() -> :ok | {:error, term()}) | nil,
          on_reload: (map() -> :ok) | nil
        ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(watch_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the most recently loaded configuration map, or `nil` if the file
  has not been successfully loaded yet.
  """
  @spec current(atom() | pid()) :: map() | nil
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  end

  @doc """
  Forces an immediate reload of the watched file, bypassing debounce.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec reload(atom() | pid()) :: :ok | {:error, term()}
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    format = Keyword.get(opts, :format, :json)
    validator = Keyword.get(opts, :validator)
    on_reload = Keyword.get(opts, :on_reload)

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
    FileSystem.subscribe(watcher_pid)

    state = %{
      path: path,
      format: format,
      validator: validator,
      on_reload: on_reload,
      current_config: nil,
      watcher_pid: watcher_pid,
      debounce_ref: nil
    }

    new_state = do_load(state)
    {:ok, new_state}
  end

  @impl GenServer
  def handle_call(:current, _from, state) do
    {:reply, state.current_config, state}
  end

  def handle_call(:reload, _from, state) do
    new_state = do_load(state)

    if new_state.current_config != state.current_config do
      {:reply, :ok, new_state}
    else
      {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_info({:file_event, _pid, {path, events}}, %{path: watched_path} = state) do
    if Path.expand(path) == Path.expand(watched_path) and :modified in events do
      if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
      ref = Process.send_after(self(), :debounced_reload, @debounce_ms)
      {:noreply, %{state | debounce_ref: ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:debounced_reload, state) do
    new_state = do_load(%{state | debounce_ref: nil})
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_load(state) do
    case load_and_parse(state.path, state.format) do
      {:ok, config} ->
        case validate(config, state.validator) do
          :ok ->
            apply_config(config, state)

          {:error, reason} ->
            Logger.error("Config validation failed, keeping current config",
              path: state.path,
              reason: inspect(reason)
            )

            state
        end

      {:error, reason} ->
        Logger.error("Config file load failed",
          path: state.path,
          reason: inspect(reason)
        )

        state
    end
  end

  defp apply_config(config, state) do
    if state.on_reload, do: state.on_reload.(config)

    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {:config_reloaded, config})

    Logger.info("Configuration reloaded", path: state.path)
    %{state | current_config: config}
  end

  defp load_and_parse(path, :json) do
    with {:ok, content} <- File.read(path),
         {:ok, map} <- Jason.decode(content) do
      {:ok, map}
    end
  end

  defp load_and_parse(path, :toml) do
    with {:ok, content} <- File.read(path),
         {:ok, map} <- Toml.decode(content) do
      {:ok, map}
    end
  end

  defp validate(_config, nil), do: :ok
  defp validate(config, validator) when is_function(validator, 1), do: validator.(config)
end
```
