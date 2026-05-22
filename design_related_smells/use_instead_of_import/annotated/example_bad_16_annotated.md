# Annotated Bad Example 16

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Logistics.ShipmentProcessor`, `use Logistics.TrackingHelpers` directive
**Affected Functions:** `new/1`, `transition/4`, `retry_transition/4`, `describe/1`, `tracking_url/1`
**Explanation:** `Logistics.ShipmentProcessor` uses `use Logistics.TrackingHelpers` to access status-transition predicates and event builders. However, `TrackingHelpers.__using__/1` silently injects aliases for `Logistics.EventLog` and `Logistics.CarrierRegistry` and sets `@max_retries` and `@retry_delay_ms` module attributes. The client is unaware of these propagated dependencies. A plain `import Logistics.TrackingHelpers` would have made only the needed functions available without the hidden side-effects.

```elixir
defmodule Logistics.TrackingHelpers do
  @moduledoc """
  Predicates and factories for shipment status transitions and event entries.
  """

  def valid_transition?(:created,          :picked_up),        do: true
  def valid_transition?(:picked_up,        :in_transit),        do: true
  def valid_transition?(:in_transit,       :out_for_delivery),  do: true
  def valid_transition?(:out_for_delivery, :delivered),         do: true
  def valid_transition?(:in_transit,       :exception),         do: true
  def valid_transition?(:out_for_delivery, :exception),         do: true
  def valid_transition?(_,                 _),                  do: false

  def status_label(:created),          do: "Shipment Created"
  def status_label(:picked_up),        do: "Picked Up by Carrier"
  def status_label(:in_transit),       do: "In Transit"
  def status_label(:out_for_delivery), do: "Out for Delivery"
  def status_label(:delivered),        do: "Delivered"
  def status_label(:exception),        do: "Exception — Manual Review Required"
  def status_label(_),                 do: "Unknown"

  def build_event(shipment_id, status, location, note \\ nil) do
    %{
      shipment_id: shipment_id,
      status:      status,
      location:    location,
      note:        note,
      timestamp:   DateTime.utc_now()
    }
  end

  def terminal?(status), do: status in [:delivered, :exception]

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 propagates two aliases
  # (Logistics.EventLog and Logistics.CarrierRegistry) and two module attributes
  # into every caller, without the caller's knowledge. A reader of ShipmentProcessor
  # must inspect this macro to understand where EventLog and CarrierRegistry come from.
  defmacro __using__(_opts) do
    quote do
      import Logistics.TrackingHelpers
      alias Logistics.EventLog
      alias Logistics.CarrierRegistry

      @max_retries    3
      @retry_delay_ms 500
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Logistics.EventLog do
  @moduledoc "Appends tracking events to the persistent event store."

  def append(%{shipment_id: id, status: s, location: l} = event) do
    IO.puts("[EventLog] #{id}: #{s} at #{l} (#{event.timestamp})")
    :ok
  end

  def history(_shipment_id), do: []
end

defmodule Logistics.CarrierRegistry do
  @moduledoc "Maps carrier codes to metadata."

  def lookup("FDX"), do: {:ok, %{name: "FedEx", url: "https://fedex.com/track"}}
  def lookup("UPS"), do: {:ok, %{name: "UPS",   url: "https://ups.com/track"}}
  def lookup("DHL"), do: {:ok, %{name: "DHL",   url: "https://dhl.com/track"}}
  def lookup(_),     do: {:error, :unknown_carrier}
end

defmodule Logistics.ShipmentProcessor do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Logistics.TrackingHelpers` expands
  # __using__/1, silently bringing EventLog and CarrierRegistry into scope as
  # aliases and injecting @max_retries and @retry_delay_ms. These hidden effects
  # make the module's true dependency surface invisible. Replacing this with
  # `import Logistics.TrackingHelpers` plus explicit aliases would be transparent.
  use Logistics.TrackingHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Processes shipment lifecycle events, validates state transitions, and persists
  tracking entries. Supports automatic retry for transient carrier API failures.
  """

  defstruct [
    :id, :tracking_number, :carrier_code,
    :current_status, :origin, :destination, :created_at
  ]

  def new(params) do
    shipment = %__MODULE__{
      id:             generate_id(),
      tracking_number: params[:tracking_number],
      carrier_code:    params[:carrier_code],
      current_status:  :created,
      origin:          params[:origin],
      destination:     params[:destination],
      created_at:      DateTime.utc_now()
    }

    EventLog.append(build_event(shipment.id, :created, shipment.origin, "Shipment created"))
    shipment
  end

  def transition(%__MODULE__{current_status: cur} = shipment, new_status, location, note \\ nil) do
    if valid_transition?(cur, new_status) do
      EventLog.append(build_event(shipment.id, new_status, location, note))
      {:ok, %{shipment | current_status: new_status}}
    else
      {:error, "Invalid transition #{cur} → #{new_status}"}
    end
  end

  def retry_transition(%__MODULE__{} = shipment, new_status, location, attempt \\ 1) do
    case transition(shipment, new_status, location) do
      {:ok, _} = ok  -> ok
      {:error, _} when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms)
        retry_transition(shipment, new_status, location, attempt + 1)
      {:error, _} = err -> err
    end
  end

  def tracking_url(%__MODULE__{carrier_code: code, tracking_number: num}) do
    case CarrierRegistry.lookup(code) do
      {:ok, carrier} -> {:ok, "#{carrier.url}?number=#{num}"}
      {:error, _} = e -> e
    end
  end

  def describe(%__MODULE__{} = s) do
    """
    Shipment    : #{s.id}
    Tracking #  : #{s.tracking_number}
    Carrier     : #{s.carrier_code}
    Status      : #{status_label(s.current_status)}
    Origin      : #{s.origin}
    Destination : #{s.destination}
    Terminal    : #{terminal?(s.current_status)}
    """
  end

  defp generate_id, do: "SHP-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :upper)
end
```
