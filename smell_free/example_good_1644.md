```elixir
defmodule IoT.Devices.CommandDispatcher do
  @moduledoc """
  Dispatches commands to IoT devices through a protocol-aware gateway,
  managing acknowledgement tracking and per-device command queuing.
  """

  use GenServer, restart: :permanent

  alias IoT.Devices.{Device, Command, GatewayClient, AckTracker}

  @ack_timeout_ms 30_000
  @max_pending_per_device 20

  @type state :: %{
          pending: %{String.t() => [Command.t()]},
          ack_timers: %{String.t() => reference()}
        }

  @doc """
  Starts the command dispatcher under a supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatches a command to the specified device.

  Commands are queued per-device when the device has pending unacknowledged
  commands to preserve ordering guarantees.
  """
  @spec dispatch(Device.t(), Command.t()) ::
          {:ok, String.t()} | {:error, :queue_full} | {:error, :device_offline}
  def dispatch(%Device{} = device, %Command{} = command) do
    GenServer.call(__MODULE__, {:dispatch, device, command})
  end

  @doc """
  Acknowledges a command by its correlation ID.
  """
  @spec acknowledge(String.t()) :: :ok | {:error, :unknown_command}
  def acknowledge(correlation_id) when is_binary(correlation_id) do
    GenServer.call(__MODULE__, {:acknowledge, correlation_id})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{pending: %{}, ack_timers: %{}}}
  end

  @impl GenServer
  def handle_call({:dispatch, device, command}, _from, state) do
    device_queue = Map.get(state.pending, device.id, [])

    if length(device_queue) >= @max_pending_per_device do
      {:reply, {:error, :queue_full}, state}
    else
      correlation_id = generate_correlation_id(device.id, command)
      tagged_command = %{command | correlation_id: correlation_id}

      case send_command(device, tagged_command) do
        :ok ->
          timer_ref = schedule_ack_timeout(correlation_id)
          new_pending = Map.update(state.pending, device.id, [tagged_command], &[tagged_command | &1])
          new_timers = Map.put(state.ack_timers, correlation_id, timer_ref)
          {:reply, {:ok, correlation_id}, %{state | pending: new_pending, ack_timers: new_timers}}

        {:error, :offline} ->
          {:reply, {:error, :device_offline}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:acknowledge, correlation_id}, _from, state) do
    case Map.pop(state.ack_timers, correlation_id) do
      {nil, _} ->
        {:reply, {:error, :unknown_command}, state}

      {timer_ref, remaining_timers} ->
        Process.cancel_timer(timer_ref)
        AckTracker.record_ack(correlation_id)
        new_state = %{state | ack_timers: remaining_timers}
        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_info({:ack_timeout, correlation_id}, state) do
    AckTracker.record_timeout(correlation_id)
    new_timers = Map.delete(state.ack_timers, correlation_id)
    {:noreply, %{state | ack_timers: new_timers}}
  end

  defp send_command(%Device{status: :offline}, _command), do: {:error, :offline}

  defp send_command(%Device{} = device, command) do
    GatewayClient.send(device.gateway_id, device.id, command)
  end

  defp schedule_ack_timeout(correlation_id) do
    Process.send_after(self(), {:ack_timeout, correlation_id}, @ack_timeout_ms)
  end

  defp generate_correlation_id(device_id, %Command{type: type}) do
    salt = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{device_id}:#{type}:#{salt}"
  end
end
```
