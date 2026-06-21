# File: `example_good_10.md`

```elixir
defmodule Shipping.TrackingPoller do
  @moduledoc """
  GenServer that periodically polls a carrier API for shipment tracking
  updates and broadcasts status changes via Phoenix.PubSub.

  Each poll cycle fetches only the subset of shipments in an active
  state, minimising payload size and carrier API quota consumption.
  """

  use GenServer

  require Logger

  alias Shipping.{Carrier, Shipment, ShipmentStore}

  @pubsub MyApp.PubSub
  @tracking_topic "shipments:tracking"

  @default_poll_interval_ms 60_000
  @active_statuses [:pending, :in_transit, :out_for_delivery]

  @type opts :: [
          poll_interval_ms: pos_integer(),
          carrier: module()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the timestamp of the most recent completed poll cycle.

  Returns `{:ok, datetime}` or `{:error, :never_polled}` if no poll
  has completed since the process started.
  """
  @spec last_polled_at() :: {:ok, DateTime.t()} | {:error, :never_polled}
  def last_polled_at do
    GenServer.call(__MODULE__, :last_polled_at)
  end

  @doc """
  Triggers an immediate out-of-band poll cycle, bypassing the
  regular interval timer.
  """
  @spec poll_now() :: :ok
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  @impl GenServer
  def init(opts) do
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    carrier = Keyword.get(opts, :carrier, Carrier.Default)

    state = %{
      poll_interval_ms: poll_interval_ms,
      carrier: carrier,
      last_polled_at: nil
    }

    schedule_poll(poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:last_polled_at, _from, %{last_polled_at: nil} = state) do
    {:reply, {:error, :never_polled}, state}
  end

  @impl GenServer
  def handle_call(:last_polled_at, _from, %{last_polled_at: ts} = state) do
    {:reply, {:ok, ts}, state}
  end

  @impl GenServer
  def handle_cast(:poll_now, state) do
    new_state = run_poll(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = run_poll(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  defp run_poll(state) do
    active_shipments = ShipmentStore.list_by_statuses(@active_statuses)

    tracking_numbers = Enum.map(active_shipments, & &1.tracking_number)

    case state.carrier.fetch_statuses(tracking_numbers) do
      {:ok, status_map} ->
        apply_updates(active_shipments, status_map)

      {:error, reason} ->
        Logger.error("Tracking poll failed: #{inspect(reason)}")
    end

    %{state | last_polled_at: DateTime.utc_now()}
  end

  defp apply_updates(shipments, status_map) do
    Enum.each(shipments, fn shipment ->
      status_map
      |> Map.get(shipment.tracking_number)
      |> apply_status_to_shipment(shipment)
    end)
  end

  defp apply_status_to_shipment(nil, _shipment), do: :ok

  defp apply_status_to_shipment(new_status, %Shipment{status: current_status} = shipment)
       when new_status != current_status do
    case ShipmentStore.update_status(shipment, new_status) do
      {:ok, updated} ->
        broadcast_status_change(updated)

      {:error, reason} ->
        Logger.warning("Failed to update shipment #{shipment.id}: #{inspect(reason)}")
    end
  end

  defp apply_status_to_shipment(_same_status, _shipment), do: :ok

  defp broadcast_status_change(%Shipment{} = shipment) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      @tracking_topic,
      {:shipment_status_changed, shipment.id, shipment.status}
    )
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
