# Code Smell Annotation

- **Smell name:** Unsupervised Process
- **Expected smell location:** `ShipmentTracker.track/2`
- **Affected function(s):** `track/2`
- **Short explanation:** `GenServer.start/3` is called directly without registering the process under any supervisor. Each shipment spawns a long-lived tracking process that polls a carrier API, but these processes exist outside the OTP supervision tree, making it impossible to manage their lifecycle, detect crashes, or shut them down during application restarts.

---

```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Tracks the real-time status of individual shipments by polling the carrier API
  at regular intervals and broadcasting updates to subscribers.

  Each shipment is assigned its own GenServer process for independent tracking.
  """

  use GenServer

  alias Logistics.{CarrierAPI, EventBus, ShipmentStore}

  @poll_interval_ms 30_000
  @terminal_statuses [:delivered, :failed, :returned]

  defstruct [
    :shipment_id,
    :carrier,
    :tracking_number,
    :subscriber_pids,
    :last_status,
    :poll_count
  ]

  ## Public API

  @doc """
  Begins tracking a shipment. Starts a dedicated GenServer process
  that polls the carrier for status updates until a terminal state is reached.
  """
  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` is used to spin up
  # a long-running shipment tracking process with no link to a supervisor.
  # The process lives indefinitely (or until delivery), and if it crashes due to
  # a network error or bug, no supervisor will restart it. There is no visibility
  # into how many such processes exist at any time, and they cannot be cleanly
  # stopped during application shutdown.
  def track(shipment_id, opts \\ []) do
    carrier = Keyword.fetch!(opts, :carrier)
    tracking_number = Keyword.fetch!(opts, :tracking_number)

    GenServer.start(
      __MODULE__,
      %{
        shipment_id: shipment_id,
        carrier: carrier,
        tracking_number: tracking_number
      },
      name: process_name(shipment_id)
    )
  end
  # VALIDATION: SMELL END

  @doc """
  Subscribes the calling process to status update events for the given shipment.
  """
  def subscribe(shipment_id) do
    GenServer.call(process_name(shipment_id), {:subscribe, self()})
  catch
    :exit, _ -> {:error, :tracker_not_running}
  end

  @doc """
  Returns the last known status for the given shipment.
  """
  def current_status(shipment_id) do
    GenServer.call(process_name(shipment_id), :current_status)
  catch
    :exit, _ -> {:error, :tracker_not_running}
  end

  @doc """
  Stops the tracking process for a shipment.
  """
  def stop(shipment_id) do
    GenServer.stop(process_name(shipment_id))
  catch
    :exit, _ -> :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(%{shipment_id: shipment_id, carrier: carrier, tracking_number: tracking_number}) do
    state = %__MODULE__{
      shipment_id: shipment_id,
      carrier: carrier,
      tracking_number: tracking_number,
      subscriber_pids: [],
      last_status: nil,
      poll_count: 0
    }

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscriber_pids: [pid | state.subscriber_pids]}}
  end

  @impl true
  def handle_call(:current_status, _from, state) do
    {:reply, {:ok, state.last_status}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case CarrierAPI.fetch_status(state.carrier, state.tracking_number) do
      {:ok, status_event} ->
        new_state = handle_status_update(state, status_event)
        {:noreply, new_state}

      {:error, reason} ->
        ShipmentStore.record_poll_error(state.shipment_id, reason)
        schedule_poll()
        {:noreply, %{state | poll_count: state.poll_count + 1}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    remaining = Enum.reject(state.subscriber_pids, &(&1 == pid))
    {:noreply, %{state | subscriber_pids: remaining}}
  end

  ## Private Helpers

  defp handle_status_update(state, %{status: status} = event) do
    ShipmentStore.upsert_status(state.shipment_id, event)
    EventBus.broadcast({:shipment_update, state.shipment_id, event})
    notify_subscribers(state.subscriber_pids, event)

    new_state = %{state | last_status: status, poll_count: state.poll_count + 1}

    if status in @terminal_statuses do
      {:stop, :normal, new_state}
      new_state
    else
      schedule_poll()
      new_state
    end
  end

  defp notify_subscribers(pids, event) do
    Enum.each(pids, fn pid ->
      send(pid, {:shipment_event, event})
    end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp process_name(shipment_id) do
    {:via, Registry, {Logistics.TrackerRegistry, shipment_id}}
  end
end
```
