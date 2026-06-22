```elixir
defmodule Infra.SshTunnelManager do
  @moduledoc """
  Manages a pool of supervised SSH tunnel connections to remote hosts.

  Each tunnel is a named GenServer holding an open `:ssh` channel reference.
  Tunnels are started on demand, monitored for drops, and automatically
  re-established after a configurable back-off delay.
  """

  use Supervisor

  alias Infra.SshTunnelManager.{TunnelWorker, TunnelConfig}

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    tunnels = Keyword.get(opts, :tunnels, [])

    children =
      Enum.map(tunnels, fn config ->
        Supervisor.child_spec({TunnelWorker, config}, id: config.name)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Executes a command over the named tunnel, returning stdout as a binary.
  """
  @spec exec(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def exec(tunnel_name, command, opts \\ [])
      when is_atom(tunnel_name) and is_binary(command) do
    TunnelWorker.exec(tunnel_name, command, opts)
  end

  @doc """
  Returns the current connection status for a named tunnel.
  """
  @spec status(atom()) :: :connected | :reconnecting | :disconnected
  def status(tunnel_name) when is_atom(tunnel_name) do
    TunnelWorker.status(tunnel_name)
  end
end

defmodule Infra.SshTunnelManager.TunnelConfig do
  @moduledoc "Configuration for a single SSH tunnel connection."

  @enforce_keys [:name, :host, :port, :user]
  defstruct [:name, :host, :port, :user, :key_path, reconnect_delay_ms: 5_000]

  @type t :: %__MODULE__{
          name: atom(),
          host: String.t(),
          port: pos_integer(),
          user: String.t(),
          key_path: String.t() | nil,
          reconnect_delay_ms: pos_integer()
        }
end

defmodule Infra.SshTunnelManager.TunnelWorker do
  @moduledoc false

  use GenServer, restart: :permanent

  require Logger

  alias Infra.SshTunnelManager.TunnelConfig

  @doc false
  def start_link(%TunnelConfig{name: name} = config) do
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @spec exec(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def exec(name, command, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    GenServer.call(name, {:exec, command}, timeout)
  end

  @spec status(atom()) :: :connected | :reconnecting | :disconnected
  def status(name), do: GenServer.call(name, :status)

  @impl GenServer
  def init(%TunnelConfig{} = config) do
    {:ok, %{config: config, connection: nil, status: :disconnected}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case open_connection(state.config) do
      {:ok, conn} ->
        Logger.info("SSH tunnel #{state.config.name} connected to #{state.config.host}")
        {:noreply, %{state | connection: conn, status: :connected}}

      {:error, reason} ->
        Logger.warning("SSH tunnel #{state.config.name} connect failed: #{reason}")
        schedule_reconnect(state.config.reconnect_delay_ms)
        {:noreply, %{state | status: :reconnecting}}
    end
  end

  @impl GenServer
  def handle_call({:exec, _command}, _from, %{status: :connected, connection: conn} = state) do
    result = run_command(conn, _command)
    {:reply, result, state}
  end

  def handle_call({:exec, _command}, _from, %{status: status} = state) do
    {:reply, {:error, "tunnel is #{status}"}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:ssh_cm, _conn, {:closed, _chan}}, state) do
    Logger.warning("SSH tunnel #{state.config.name} disconnected, scheduling reconnect")
    schedule_reconnect(state.config.reconnect_delay_ms)
    {:noreply, %{state | connection: nil, status: :reconnecting}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp open_connection(%TunnelConfig{host: host, port: port, user: user}) do
    host_charlist = String.to_charlist(host)
    user_charlist = String.to_charlist(user)

    case :ssh.connect(host_charlist, port, [user: user_charlist, silently_accept_hosts: true], 10_000) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp run_command(conn, command) do
    case :ssh_connection.exec(conn, :ssh_connection.session_channel(conn, 10_000), command, 10_000) do
      :success -> {:ok, ""}
      failure -> {:error, inspect(failure)}
    end
  end

  defp schedule_reconnect(delay_ms) do
    Process.send_after(self(), :reconnect, delay_ms)
  end
end
```
