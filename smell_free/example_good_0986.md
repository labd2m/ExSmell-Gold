```elixir
defmodule MyAppWeb.ConnectionDrainer do
  @moduledoc """
  Coordinates zero-downtime restarts by delaying the VM shutdown sequence
  until all in-flight HTTP requests have completed or a maximum drain
  timeout elapses. Integrates with the Phoenix endpoint via a custom
  shutdown handler and tracks active connections using an ETS counter.
  When deployed behind a load balancer that respects the `Connection: close`
  header, this module prevents request drops during rolling deployments.
  """

  use GenServer

  require Logger

  @table :connection_drainer
  @drain_timeout_ms 30_000
  @poll_interval_ms 200

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increments the active connection counter. Call at the start of each request.
  """
  @spec connection_opened() :: :ok
  def connection_opened do
    :ets.update_counter(@table, :active, {2, 1})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Decrements the active connection counter. Call when a request completes.
  """
  @spec connection_closed() :: :ok
  def connection_closed do
    :ets.update_counter(@table, :active, {2, -1, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the number of currently active connections.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    case :ets.lookup(@table, :active) do
      [{:active, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Blocks until all in-flight connections complete or the drain timeout elapses.
  Intended to be called from the `:init.stop/0` shutdown path.
  """
  @spec drain() :: :ok | {:error, :timeout}
  def drain do
    GenServer.call(__MODULE__, :drain, @drain_timeout_ms + 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public])
    :ets.insert(@table, {:active, 0})
    {:ok, %{draining: false, drain_caller: nil}}
  end

  @impl GenServer
  def handle_call(:drain, from, state) do
    Logger.info("Connection drain initiated", active: active_count())

    if active_count() == 0 do
      {:reply, :ok, state}
    else
      schedule_drain_check()
      deadline = System.monotonic_time(:millisecond) + @drain_timeout_ms
      {:noreply, %{state | draining: true, drain_caller: {from, deadline}}}
    end
  end

  @impl GenServer
  def handle_info(:check_drain, %{drain_caller: {from, deadline}} = state) do
    now = System.monotonic_time(:millisecond)
    count = active_count()

    cond do
      count == 0 ->
        Logger.info("All connections drained")
        GenServer.reply(from, :ok)
        {:noreply, %{state | draining: false, drain_caller: nil}}

      now >= deadline ->
        Logger.warning("Drain timeout elapsed", remaining_connections: count)
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | draining: false, drain_caller: nil}}

      true ->
        Logger.debug("Waiting for connections to drain", active: count)
        schedule_drain_check()
        {:noreply, state}
    end
  end

  def handle_info(:check_drain, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Plug integration
  # ---------------------------------------------------------------------------

  defp schedule_drain_check do
    Process.send_after(self(), :check_drain, @poll_interval_ms)
  end
end

defmodule MyAppWeb.Plug.TrackConnection do
  @moduledoc """
  Plug that registers and deregisters each request with `ConnectionDrainer`.
  Place at the top of the endpoint's plug pipeline so all request durations
  are tracked.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    MyAppWeb.ConnectionDrainer.connection_opened()
    register_before_send(conn, fn c ->
      MyAppWeb.ConnectionDrainer.connection_closed()
      c
    end)
  end
end
```
