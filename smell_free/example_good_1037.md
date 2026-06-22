```elixir
defmodule OsProcess.Config do
  @moduledoc false

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          cd: String.t() | nil,
          max_restarts: non_neg_integer(),
          restart_delay_ms: pos_integer()
        }

  defstruct [
    :command,
    :cd,
    args: [],
    env: [],
    max_restarts: 3,
    restart_delay_ms: 1_000
  ]
end

defmodule OsProcess.Manager do
  @moduledoc """
  Wraps an external OS process in a supervised GenServer, capturing stdout
  and stderr and optionally restarting the process when it exits unexpectedly.

  Subscribers receive `{:os_process_output, pid(), line}` messages for each
  line of output and `{:os_process_exit, pid(), status}` when the process
  terminates. The manager stops restarting after `max_restarts` consecutive
  failures to prevent an infinite crash loop.
  """

  use GenServer

  require Logger

  alias OsProcess.Config

  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(%Config{} = config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @spec send_input(GenServer.server(), binary()) :: :ok | {:error, :not_running}
  def send_input(server, data) when is_binary(data) do
    GenServer.call(server, {:send_input, data})
  end

  @spec stop_process(GenServer.server()) :: :ok
  def stop_process(server) do
    GenServer.call(server, :stop_process)
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()) do
    GenServer.cast(server, {:subscribe, pid})
  end

  @spec status(GenServer.server()) :: :running | :stopped | {:restarting, pos_integer()}
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl GenServer
  def init(%Config{} = config) do
    state = %{
      config: config,
      port: nil,
      restarts: 0,
      subscribers: [],
      buffer: "",
      status: :stopped
    }

    {:ok, start_port(state)}
  end

  @impl GenServer
  def handle_call({:send_input, data}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:send_input, data}, _from, %{port: port} = state) do
    Port.command(port, data)
    {:reply, :ok, state}
  end

  def handle_call(:stop_process, _from, state) do
    if state.port, do: Port.close(state.port)
    {:reply, :ok, %{state | port: nil, status: :stopped, restarts: state.config.max_restarts}}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, remaining} = split_lines(state.buffer <> to_string(data))
    Enum.each(lines, &broadcast(state.subscribers, {:os_process_output, self(), &1}))
    {:noreply, %{state | buffer: remaining}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    broadcast(state.subscribers, {:os_process_exit, self(), status})
    Logger.warning("OS process exited", command: state.config.command, status: status)

    new_state =
      if state.restarts < state.config.max_restarts and status != 0 do
        Process.send_after(self(), :restart, state.config.restart_delay_ms)
        %{state | port: nil, status: {:restarting, state.restarts + 1}}
      else
        %{state | port: nil, status: :stopped}
      end

    {:noreply, new_state}
  end

  def handle_info(:restart, state) do
    Logger.info("Restarting OS process", command: state.config.command, attempt: state.restarts + 1)
    {:noreply, start_port(%{state | restarts: state.restarts + 1})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_port(state) do
    %Config{command: cmd, args: args, env: env, cd: cd} = state.config

    port_opts =
      [:binary, :exit_status, {:args, args}, {:env, env}]
      |> then(fn opts -> if cd, do: [{:cd, cd} | opts], else: opts end)

    port = Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, port_opts)
    %{state | port: port, status: :running}
  end

  defp split_lines(data) do
    lines = String.split(data, "\n")
    {Enum.drop(lines, -1), List.last(lines)}
  end

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end
end
```
