```elixir
# ── file: lib/logistics/shipment.ex ─────────────────────────────────────────


defmodule Logistics.Shipment do
  @moduledoc """
  Core shipment entity and lifecycle management.
  Defined in `lib/logistics/shipment.ex`.
  """

  @statuses [:pending, :picked_up, :in_transit, :out_for_delivery, :delivered, :failed]

  @type status :: :pending | :picked_up | :in_transit | :out_for_delivery | :delivered | :failed

  @type t :: %__MODULE__{
    id: String.t(),
    order_id: String.t(),
    carrier: String.t() | nil,
    status: status(),
    origin: map(),
    destination: map(),
    weight_kg: float(),
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  defstruct [
    :id,
    :order_id,
    :carrier,
    :origin,
    :destination,
    :weight_kg,
    status: :pending,
    created_at: nil,
    updated_at: nil
  ]

  @doc "Create a new shipment record for an order."
  @spec create(String.t(), map(), map()) :: t()
  def create(order_id, origin, destination) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      order_id: order_id,
      origin: origin,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc "Transition the shipment to a new status."
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, String.t()}
  def update_status(%__MODULE__{} = shipment, new_status)
      when new_status in @statuses do
    if valid_transition?(shipment.status, new_status) do
      {:ok, %{shipment | status: new_status, updated_at: DateTime.utc_now()}}
    else
      {:error, "Invalid transition from #{shipment.status} to #{new_status}"}
    end
  end

  def update_status(_shipment, bad_status) do
    {:error, "Unknown status: #{bad_status}"}
  end

  @doc "Assign a carrier to the shipment."
  @spec assign_carrier(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def assign_carrier(%__MODULE__{status: :pending} = shipment, carrier) do
    {:ok, %{shipment | carrier: carrier, updated_at: DateTime.utc_now()}}
  end

  def assign_carrier(_shipment, _carrier) do
    {:error, "Carrier can only be assigned to pending shipments"}
  end

  @doc "Return the estimated delivery date based on origin/destination distance."
  @spec estimated_delivery(t()) :: Date.t()
  def estimated_delivery(%__MODULE__{created_at: created_at, origin: o, destination: d}) do
    days = estimate_days(o, d)
    Date.add(DateTime.to_date(created_at), days)
  end

  defp estimate_days(%{country: c1}, %{country: c2}) when c1 == c2, do: 3
  defp estimate_days(_o, _d), do: 10

  defp valid_transition?(:pending, :picked_up), do: true
  defp valid_transition?(:picked_up, :in_transit), do: true
  defp valid_transition?(:in_transit, :out_for_delivery), do: true
  defp valid_transition?(:out_for_delivery, :delivered), do: true
  defp valid_transition?(:out_for_delivery, :failed), do: true
  defp valid_transition?(_, _), do: false

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/logistics/shipment_tracking.ex ─────────────────────────────────────────────────────


defmodule Logistics.Shipment do
  @moduledoc """
  Shipment tracking and carrier URL utilities.
  """

  @carrier_url_templates %{
    "fedex" => "https://www.fedex.com/tracking?tracknumbers=",
    "ups" => "https://www.ups.com/track?tracknum=",
    "dhl" => "https://www.dhl.com/en/express/tracking.html?AWB=",
    "usps" => "https://tools.usps.com/go/TrackConfirmAction?tLabels="
  }

  @doc "Build a public tracking URL for the shipment."
  @spec tracking_url(map()) :: {:ok, String.t()} | {:error, String.t()}
  def tracking_url(%{carrier: carrier, id: shipment_id})
      when is_binary(carrier) do
    base = Map.get(@carrier_url_templates, String.downcase(carrier))

    if base do
      {:ok, base <> shipment_id}
    else
      {:error, "No tracking URL template for carrier: #{carrier}"}
    end
  end

  def tracking_url(_shipment) do
    {:error, "Shipment has no carrier assigned"}
  end

  @doc "Parse raw carrier webhook events into a normalized status atom."
  @spec parse_carrier_event(String.t(), map()) ::
          {:ok, atom()} | {:error, String.t()}
  def parse_carrier_event("fedex", %{"EventType" => type}) do
    case type do
      "PU" -> {:ok, :picked_up}
      "IT" -> {:ok, :in_transit}
      "OD" -> {:ok, :out_for_delivery}
      "DL" -> {:ok, :delivered}
      _ -> {:error, "Unknown FedEx event: #{type}"}
    end
  end

  def parse_carrier_event("ups", %{"ActivityStatus" => %{"Type" => type}}) do
    case type do
      "I" -> {:ok, :in_transit}
      "D" -> {:ok, :delivered}
      "X" -> {:ok, :failed}
      _ -> {:error, "Unknown UPS activity type: #{type}"}
    end
  end

  def parse_carrier_event(carrier, _payload) do
    {:error, "Unsupported carrier for event parsing: #{carrier}"}
  end
end

```
