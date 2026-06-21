```elixir
defmodule Platform.LiveConfig do
  @moduledoc """
  A GenServer that periodically reloads configuration from an external
  source (database, key-value store, or remote config service) and
  broadcasts changes to subscribers via PubSub.

  Subscribers receive `{:config_changed, key, old_value, new_value}` messages.
  Read operations on the latest config values query ETS directly without
  passing through the GenServer, ensuring low-latency reads.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @type config_key :: atom()
  @type config_value :: term()
  @type fetch_fn :: (-> {:ok, %{optional(config_key()) => config_value()}} | {:error, term()})

  @pubsub_topic "live_config:changed"
  @default_reload_ms :timer.seconds(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current value for `key`, or `default` if not set."
  @spec get(config_key(), term()) :: config_value()
  def get(key, default \\ nil) when is_atom(key) do
    table = :persistent_term.get({__MODULE__, :table})

    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc "Returns all currently loaded configuration as a map."
  @spec all() :: %{optional(config_key()) => config_value()}
  def all do
    table = :persistent_term.get({__MODULE__, :table})
    :ets.tab2list(table) |> Map.new()
  end

  @doc "Subscribes the calling process to config change notifications."
  @spec subscribe(atom()) :: :ok | {:error, term()}
  def subscribe(pubsub \\ Platform.PubSub) do
    PubSub.subscribe(pubsub, @pubsub_topic)
  end

  @doc "Forces an immediate configuration reload outside the normal schedule."
  @spec reload() :: :ok
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @impl GenServer
  def init(opts) do
    fetch_fn = Keyword.fetch!(opts, :fetch_fn)
    reload_ms = Keyword.get(opts, :reload_interval_ms, @default_reload_ms)
    pubsub = Keyword.get(opts, :pubsub, Platform.PubSub)

    table = :ets.new(:live_config, [:set, :public, :named_table, read_concurrency: true])
    :persistent_term.put({__MODULE__, :table}, table)

    state = %{fetch_fn: fetch_fn, reload_ms: reload_ms, pubsub: pubsub, table: table}

    case load(state) do
      {:ok, new_state} ->
        schedule_reload(reload_ms)
        {:ok, new_state}

      {:error, reason} ->
        {:stop, {:initial_load_failed, reason}}
    end
  end

  @impl GenServer
  def handle_cast(:reload, state) do
    {:noreply, reload_and_notify(state)}
  end

  @impl GenServer
  def handle_info(:reload, %{reload_ms: reload_ms} = state) do
    schedule_reload(reload_ms)
    {:noreply, reload_and_notify(state)}
  end

  defp reload_and_notify(state) do
    case load(state) do
      {:ok, new_state} -> new_state
      {:error, reason} ->
        Logger.error("[LiveConfig] Reload failed", reason: inspect(reason))
        state
    end
  end

  defp load(%{fetch_fn: fetch_fn, table: table, pubsub: pubsub} = state) do
    case fetch_fn.() do
      {:ok, new_config} ->
        old_config = :ets.tab2list(table) |> Map.new()
        apply_config(table, new_config)
        broadcast_changes(pubsub, old_config, new_config)
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_config(table, config) do
    :ets.delete_all_objects(table)
    Enum.each(config, fn {key, value} -> :ets.insert(table, {key, value}) end)
  end

  defp broadcast_changes(pubsub, old_config, new_config) do
    changed_keys = Enum.filter(new_config, fn {k, v} -> Map.get(old_config, k) != v end)

    Enum.each(changed_keys, fn {key, new_value} ->
      old_value = Map.get(old_config, key)
      PubSub.broadcast(pubsub, @pubsub_topic, {:config_changed, key, old_value, new_value})
      Logger.info("[LiveConfig] Config updated", key: key)
    end)
  end

  defp schedule_reload(interval), do: Process.send_after(self(), :reload, interval)
end
```
