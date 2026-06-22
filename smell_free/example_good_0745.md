# File: `example_good_745.md`

```elixir
defmodule Infra.ConfigWatcher do
  @moduledoc """
  GenServer that watches a JSON or keyword-list configuration file for
  changes and reloads it into the application environment on modification.

  A subscriber list receives a message on each successful reload so that
  processes depending on configuration can react without polling
  the application environment themselves.
  """

  use GenServer

  require Logger

  @poll_interval_ms 5_000

  @type config_key :: atom()
  @type watcher_opts :: [
          path: String.t(),
          app: atom(),
          key: config_key(),
          poll_interval_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the calling process to configuration reload notifications.

  On each reload the subscriber receives `{:config_reloaded, key, new_value}`.
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.cast(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribes the calling process from reload notifications.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.cast(__MODULE__, {:unsubscribe, self()})
  end

  @doc """
  Forces an immediate configuration reload regardless of whether
  the file has changed.

  Returns `{:ok, new_value}` or `{:error, reason}`.
  """
  @spec reload() :: {:ok, term()} | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Returns the currently loaded configuration value.
  """
  @spec current() :: term()
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    app = Keyword.fetch!(opts, :app)
    key = Keyword.fetch!(opts, :key)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)

    state = %{
      path: path,
      app: app,
      key: key,
      poll_interval_ms: poll_interval_ms,
      last_mtime: nil,
      current_value: nil,
      subscribers: MapSet.new()
    }

    case load_config(state) do
      {:ok, new_state} ->
        schedule_poll(poll_interval_ms)
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("ConfigWatcher: initial load failed: #{inspect(reason)}")
        schedule_poll(poll_interval_ms)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    case load_config(state) do
      {:ok, new_state} ->
        notify_subscribers(new_state)
        {:reply, {:ok, new_state.current_value}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:current, _from, state) do
    {:reply, state.current_value, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state =
      case file_modified?(state) do
        true ->
          case load_config(state) do
            {:ok, updated} ->
              Logger.info("ConfigWatcher: reloaded #{state.path}")
              notify_subscribers(updated)
              updated

            {:error, reason} ->
              Logger.warning("ConfigWatcher: reload failed: #{inspect(reason)}")
              state
          end

        false ->
          state
      end

    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp load_config(state) do
    with {:ok, content} <- File.read(state.path),
         {:ok, parsed} <- parse_config(state.path, content),
         {:ok, mtime} <- file_mtime(state.path) do
      Application.put_env(state.app, state.key, parsed)
      {:ok, %{state | current_value: parsed, last_mtime: mtime}}
    end
  end

  defp parse_config(path, content) do
    cond do
      String.ends_with?(path, ".json") ->
        Jason.decode(content)

      String.ends_with?(path, ".exs") ->
        {term, _} = Code.eval_string(content)
        {:ok, term}

      true ->
        {:error, :unsupported_format}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp file_modified?(state) do
    case file_mtime(state.path) do
      {:ok, mtime} -> mtime != state.last_mtime
      {:error, _} -> false
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> {:ok, mtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_subscribers(state) do
    msg = {:config_reloaded, state.key, state.current_value}
    Enum.each(state.subscribers, &send(&1, msg))
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
