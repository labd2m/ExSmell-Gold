```elixir
defmodule Rpc.ChannelPool do
  @moduledoc """
  Manages a fixed-size pool of gRPC channels to a remote service endpoint.
  Channels are round-robin distributed across callers to spread load evenly.
  A health-check loop marks degraded channels and replaces them so the pool
  always holds at least one viable connection. The pool is supervised and
  restarts automatically if the process crashes.
  """

  use GenServer

  require Logger

  @type pool_opts :: [
          endpoint: binary(),
          port: pos_integer(),
          pool_size: pos_integer(),
          health_check_interval_ms: pos_integer()
        ]

  @default_pool_size 5
  @default_health_interval_ms 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(pool_opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks out a healthy channel from the pool. The same channel reference
  must be returned via `checkin/2` after use so health metrics stay accurate.
  Returns `{:ok, channel}` or `{:error, :no_healthy_channels}`.
  """
  @spec checkout(atom() | pid()) :: {:ok, GRPC.Channel.t()} | {:error, :no_healthy_channels}
  def checkout(pool \\ __MODULE__) do
    GenServer.call(pool, :checkout)
  end

  @doc """
  Returns a channel to the pool and records whether the call succeeded or
  failed, informing the health-check logic.
  """
  @spec checkin(atom() | pid(), GRPC.Channel.t(), :ok | :error) :: :ok
  def checkin(pool \\ __MODULE__, channel, result) when result in [:ok, :error] do
    GenServer.cast(pool, {:checkin, channel, result})
  end

  @doc """
  Returns pool statistics for monitoring: total channels, healthy count,
  and per-channel error rates.
  """
  @spec stats(atom() | pid()) :: map()
  def stats(pool \\ __MODULE__) do
    GenServer.call(pool, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    port = Keyword.get(opts, :port, 443)
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    health_interval = Keyword.get(opts, :health_check_interval_ms, @default_health_interval_ms)

    channels = Enum.map(1..pool_size, fn _ -> open_channel(endpoint, port) end)

    state = %{
      endpoint: endpoint,
      port: port,
      pool_size: pool_size,
      channels: channels,
      cursor: 0,
      error_counts: Map.new(channels, fn {ref, _ch} -> {ref, 0} end)
    }

    schedule_health_check(health_interval)
    {:ok, Map.put(state, :health_interval, health_interval)}
  end

  @impl GenServer
  def handle_call(:checkout, _from, state) do
    healthy = Enum.filter(state.channels, fn {_ref, ch} -> ch.status == :idle end)

    case healthy do
      [] ->
        {:reply, {:error, :no_healthy_channels}, state}

      _ ->
        index = rem(state.cursor, length(healthy))
        {_ref, channel} = Enum.at(healthy, index)
        {:reply, {:ok, channel}, %{state | cursor: state.cursor + 1}}
    end
  end

  def handle_call(:stats, _from, state) do
    healthy_count = Enum.count(state.channels, fn {_ref, ch} -> ch.status == :idle end)

    stats = %{
      total: length(state.channels),
      healthy: healthy_count,
      degraded: length(state.channels) - healthy_count,
      error_counts: state.error_counts
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:checkin, _channel, :ok}, state), do: {:noreply, state}

  def handle_cast({:checkin, channel, :error}, state) do
    new_counts = Map.update(state.error_counts, channel.ref, 1, &(&1 + 1))
    {:noreply, %{state | error_counts: new_counts}}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    new_channels =
      Enum.map(state.channels, fn {ref, ch} ->
        errors = Map.get(state.error_counts, ref, 0)

        if errors >= 5 do
          Logger.warning("Replacing degraded gRPC channel",
            endpoint: state.endpoint,
            error_count: errors
          )
          GRPC.Stub.disconnect(ch)
          open_channel(state.endpoint, state.port)
        else
          {ref, ch}
        end
      end)

    new_counts = Map.new(new_channels, fn {ref, _ch} -> {ref, 0} end)
    schedule_health_check(state.health_interval)
    {:noreply, %{state | channels: new_channels, error_counts: new_counts}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_channel(endpoint, port) do
    ref = make_ref()
    {:ok, channel} = GRPC.Stub.connect("#{endpoint}:#{port}", interceptors: [GRPC.Logger.Client])
    {ref, channel}
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end
end
```
