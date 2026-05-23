```elixir
defmodule Logistics.ShippingCalculator do
  @moduledoc """
  Calculates shipping costs, delivery estimates, and label formats
  for orders routed through supported carrier integrations.
  """

  alias Logistics.Address


  @spec calculate_cost(Address.t(), float(), atom()) :: float()
  def calculate_cost(%Address{domestic?: true}, weight_kg, :fedex) do
    8.50 + weight_kg * 2.50
  end

  def calculate_cost(%Address{domestic?: true}, weight_kg, :ups) do
    7.80 + weight_kg * 2.30
  end

  def calculate_cost(%Address{domestic?: true}, weight_kg, :dhl) do
    9.20 + weight_kg * 2.80
  end

  def calculate_cost(%Address{domestic?: false}, weight_kg, :fedex) do
    15.00 + weight_kg * 4.50
  end

  def calculate_cost(%Address{domestic?: false}, weight_kg, :ups) do
    14.20 + weight_kg * 4.10
  end

  def calculate_cost(%Address{domestic?: false}, weight_kg, :dhl) do
    13.50 + weight_kg * 3.90
  end

  @spec estimated_delivery_days(atom()) :: pos_integer()
  def estimated_delivery_days(:fedex), do: 2
  def estimated_delivery_days(:ups), do: 3
  def estimated_delivery_days(:dhl), do: 1

  @spec label_format(atom()) :: :pdf | :zpl
  def label_format(:fedex), do: :pdf
  def label_format(:ups), do: :zpl
  def label_format(:dhl), do: :pdf

  @spec max_insured_value(atom()) :: float()
  def max_insured_value(:fedex), do: 5_000.0
  def max_insured_value(:ups), do: 5_000.0
  def max_insured_value(:dhl), do: 3_000.0


  def calculate_order_shipping(order, address) do
    carrier = order.preferred_carrier
    weight  = order.total_weight_kg

    base_cost = calculate_cost(address, weight, carrier)
    insurance = if order.requires_insurance, do: base_cost * 0.02, else: 0.0

    %{
      carrier:        carrier,
      cost:           Float.round(base_cost + insurance, 2),
      estimated_days: estimated_delivery_days(carrier),
      label_format:   label_format(carrier)
    }
  end
end

defmodule Logistics.TrackingService do
  @moduledoc """
  Provides carrier-specific tracking URL generation and event status parsing
  for shipment visibility across the order fulfillment lifecycle.
  """


  @spec build_url(String.t(), atom()) :: String.t()
  def build_url(tracking_number, :fedex) do
    "https://www.fedex.com/fedextrack/?trknbr=#{tracking_number}"
  end

  def build_url(tracking_number, :ups) do
    "https://www.ups.com/track?tracknum=#{tracking_number}"
  end

  def build_url(tracking_number, :dhl) do
    "https://www.dhl.com/en/express/tracking.html?AWB=#{tracking_number}"
  end

  @spec parse_event_status(String.t(), atom()) :: atom()
  def parse_event_status("DL", :fedex), do: :delivered
  def parse_event_status("PU", :fedex), do: :picked_up
  def parse_event_status("OD", :fedex), do: :out_for_delivery
  def parse_event_status("IT", :fedex), do: :in_transit
  def parse_event_status("DL", :ups), do: :delivered
  def parse_event_status("PK", :ups), do: :picked_up
  def parse_event_status("OT", :ups), do: :out_for_delivery
  def parse_event_status("IP", :ups), do: :in_transit
  def parse_event_status("OK", :dhl), do: :delivered
  def parse_event_status("PU", :dhl), do: :picked_up
  def parse_event_status("WC", :dhl), do: :out_for_delivery
  def parse_event_status("TR", :dhl), do: :in_transit
  def parse_event_status(_, _),       do: :unknown


  def shipment_status(shipment) do
    case fetch_carrier_events(shipment.tracking_number, shipment.carrier) do
      {:ok, [latest | _]} ->
        status = parse_event_status(latest.code, shipment.carrier)
        url    = build_url(shipment.tracking_number, shipment.carrier)
        {:ok, %{status: status, tracking_url: url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_carrier_events(_tracking_number, _carrier) do
    {:ok, [%{code: "IT", timestamp: DateTime.utc_now()}]}
  end
end

defmodule Logistics.CarrierReport do
  @moduledoc """
  Generates carrier performance and cost reports for logistics operations.
  """


  @spec carrier_display_name(atom()) :: String.t()
  def carrier_display_name(:fedex), do: "FedEx"
  def carrier_display_name(:ups),   do: "UPS"
  def carrier_display_name(:dhl),   do: "DHL Express"

  @spec supported_carriers() :: [atom()]
  def supported_carriers, do: [:fedex, :ups, :dhl]


  def generate_monthly_report(shipments, year, month) do
    filtered = Enum.filter(shipments, fn s ->
      s.shipped_at.year == year and s.shipped_at.month == month
    end)

    grouped = Enum.group_by(filtered, & &1.carrier)

    Enum.map(supported_carriers(), fn carrier ->
      items = Map.get(grouped, carrier, [])

      %{
        carrier:          carrier_display_name(carrier),
        total_shipments:  length(items),
        total_cost:       items |> Enum.map(& &1.cost) |> Enum.sum(),
        avg_delivery_days:
          if items == [],
            do: 0.0,
            else: items |> Enum.map(& &1.actual_days) |> Enum.sum() |> Kernel./(length(items)),
        on_time_rate:
          if items == [],
            do: 0.0,
            else:
              items |> Enum.count(& &1.on_time?) |> Kernel./(length(items)) |> Kernel.*(100.0)
      }
    end)
  end
end
```
