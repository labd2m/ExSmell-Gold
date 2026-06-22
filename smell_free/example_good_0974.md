```elixir
defmodule MyApp.Ops.ConfigSynchroniser do
  @moduledoc """
  A GenServer that periodically synchronises runtime configuration from
  a remote source (AWS Parameter Store, GCP Secret Manager, etc.) into
  the local application environment. Changed values trigger a PubSub
  broadcast so that dependent services can reload without a restart.

  The synchroniser uses a content hash to avoid redundant writes and
  broadcasts when nothing has changed.
  """

  use GenServer

  require Logger

  @pubsub MyApp.PubSub
  @topic "config:sync"
  @default_interval_ms 60_000

  @type key :: String.t()
  @type value :: String.t()

  @doc "Starts the config synchroniser."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Forces an immediate synchronisation cycle."
  @spec sync_now() :: :ok
  def sync_now, do: GenServer.cast(__MODULE__, :sync)

  @doc "Subscribes the caller to config change events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    keys = Keyword.get(opts, :keys, [])
    schedule_sync(interval)
    {:ok, %{interval_ms: interval, keys: keys, hashes: %{}}}
  end

  @impl GenServer
  def handle_cast(:sync, state) do
    new_hashes = perform_sync(state.keys, state.hashes)
    {:noreply, %{state | hashes: new_hashes}}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    new_hashes = perform_sync(state.keys, state.hashes)
    schedule_sync(state.interval_ms)
    {:noreply, %{state | hashes: new_hashes}}
  end

  @spec perform_sync([key()], %{key() => binary()}) :: %{key() => binary()}
  defp perform_sync(keys, current_hashes) do
    Enum.reduce(keys, current_hashes, fn key, acc ->
      case fetch_remote_value(key) do
        {:ok, value} ->
          new_hash = :crypto.hash(:sha256, value)
          old_hash = Map.get(acc, key)

          if new_hash != old_hash do
            Elixir.Application.put_env(:my_app, String.to_atom(key), value)
            broadcast_change(key, value)

            Logger.info("config_key_updated", key: key)
            Map.put(acc, key, new_hash)
          else
            acc
          end

        {:error, reason} ->
          Logger.warning("config_fetch_failed", key: key, reason: inspect(reason))
          acc
      end
    end)
  end

  @spec fetch_remote_value(key()) :: {:ok, value()} | {:error, term()}
  defp fetch_remote_value(key) do
    MyApp.Infra.SecretManager.get(key)
  end

  @spec broadcast_change(key(), value()) :: :ok | {:error, term()}
  defp broadcast_change(key, value) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
  end

  @spec schedule_sync(pos_integer()) :: reference()
  defp schedule_sync(interval_ms),
    do: Process.send_after(self(), :sync, interval_ms)
end
```
