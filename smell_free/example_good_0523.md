```elixir
defmodule Shipping.TrackingPoller do
  @moduledoc """
  Polls an external carrier API for shipment status updates on a
  configurable schedule. Each tracked shipment runs in its own supervised
  GenServer so stalled carriers do not delay unrelated shipments. Status
  changes are broadcast on PubSub and persisted via the Shipments context.
  """

  use GenServer

  require Logger

  alias Shipping.CarrierClient
  alias Shipping.Shipments

  @type tracking_number :: String.t()
  @type carrier :: :fedex | :ups | :dhl | :usps
  @type status :: :in_transit | :out_for_delivery | :delivered | :exception | :unknown

  @terminal_statuses [:delivered, :exception]
  @default_poll_interval_ms :timer.minutes(30)

  @doc "Starts a tracking poller for a single shipment."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    tracking_number = Keyword.fetch!(opts, :tracking_number)
    carrier = Keyword.fetch!(opts, :carrier)
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    state = %{
      tracking_number: tracking_number,
      carrier: carrier,
      interval: interval,
      last_status: nil,
      poll_count: 0
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = run_poll(state)

    if new_state.last_status in @terminal_statuses do
      Logger.info("[TrackingPoller] #{state.tracking_number} reached terminal status: #{new_state.last_status}")
      {:stop, :normal, new_state}
    else
      Process.send_after(self(), :poll, state.interval)
      {:noreply, new_state}
    end
  end

  defp run_poll(%{tracking_number: tn, carrier: carrier} = state) do
    case CarrierClient.fetch_status(carrier, tn) do
      {:ok, %{status: status, location: location, updated_at: updated_at}} ->
        handle_status_update(state, status, location, updated_at)

      {:error, reason} ->
        Logger.warning("[TrackingPoller] #{tn} poll failed: #{inspect(reason)}")
        %{state | poll_count: state.poll_count + 1}
    end
  end

  defp handle_status_update(state, status, location, updated_at) do
    if status != state.last_status do
      persist_update(state.tracking_number, status, location, updated_at)
      broadcast_update(state.tracking_number, status, location)
    end

    %{state | last_status: status, poll_count: state.poll_count + 1}
  end

  defp persist_update(tracking_number, status, location, updated_at) do
    Shipments.record_tracking_event(%{
      tracking_number: tracking_number,
      status: status,
      location: location,
      event_time: updated_at
    })
  end

  defp broadcast_update(tracking_number, status, location) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "tracking:#{tracking_number}",
      {:tracking_update, %{tracking_number: tracking_number, status: status, location: location}}
    )
  end
end
```
