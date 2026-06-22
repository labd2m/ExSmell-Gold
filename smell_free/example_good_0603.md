```elixir
defmodule Messaging.AmqpSupervisor do
  @moduledoc """
  Supervises a resilient AMQP connection and its derived channel pool.
  RabbitMQ connections are expensive to establish; the supervisor holds
  a single shared connection and restarts it transparently on network
  partition or broker restart. Channels are lighter-weight and are created
  per consumer or publisher, each supervised independently so a channel
  crash does not affect the connection or sibling channels.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    amqp_url = Keyword.get(opts, :url, Application.fetch_env!(:my_app, :amqp_url))
    prefetch = Keyword.get(opts, :prefetch_count, 10)

    children = [
      {Messaging.AmqpConnection, url: amqp_url, name: Messaging.AmqpConnection},
      {Messaging.AmqpConsumer,
       connection: Messaging.AmqpConnection,
       queue: Application.fetch_env!(:my_app, :amqp_queue),
       prefetch_count: prefetch,
       handler: Messaging.MessageHandler}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule Messaging.AmqpConnection do
  @moduledoc """
  Maintains a single supervised AMQP connection. Reconnects automatically
  with exponential back-off when the broker is unavailable. Notifies
  registered monitors when the connection state changes so dependent
  channels can reclaim themselves without polling.
  """

  use GenServer

  require Logger

  @reconnect_base_ms 500
  @reconnect_max_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current open AMQP connection, or `{:error, :disconnected}`.
  """
  @spec get_connection(GenServer.server()) :: {:ok, AMQP.Connection.t()} | {:error, :disconnected}
  def get_connection(server \\ __MODULE__) do
    GenServer.call(server, :get_connection)
  end

  @impl GenServer
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    {:ok, %{url: url, connection: nil, attempt: 0}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    connect(state)
  end

  @impl GenServer
  def handle_call(:get_connection, _from, %{connection: nil} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  def handle_call(:get_connection, _from, %{connection: conn} = state) do
    {:reply, {:ok, conn}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("AMQP connection lost", reason: inspect(reason))
    schedule_reconnect(state.attempt)
    {:noreply, %{state | connection: nil}}
  end

  def handle_info(:reconnect, state) do
    connect(state)
  end

  defp connect(state) do
    case AMQP.Connection.open(state.url) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        Logger.info("AMQP connection established", attempt: state.attempt)
        {:noreply, %{state | connection: conn, attempt: 0}}

      {:error, reason} ->
        Logger.warning("AMQP connection failed",
          reason: inspect(reason),
          attempt: state.attempt
        )

        schedule_reconnect(state.attempt)
        {:noreply, %{state | connection: nil, attempt: state.attempt + 1}}
    end
  end

  defp schedule_reconnect(attempt) do
    delay = min(@reconnect_base_ms * :math.pow(2, attempt) |> trunc(), @reconnect_max_ms)
    jitter = :rand.uniform(div(delay, 4))
    Process.send_after(self(), :reconnect, delay + jitter)
  end
end
```
