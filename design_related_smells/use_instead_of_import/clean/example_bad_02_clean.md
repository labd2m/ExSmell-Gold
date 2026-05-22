```elixir
defmodule Logistics.GeoUtils do
  @moduledoc """
  Geographic coordinate utilities used across the logistics platform.
  """

  def haversine_km({lat1, lon1}, {lat2, lon2}) do
    r    = 6_371
    dlat = :math.pi() / 180 * (lat2 - lat1)
    dlon = :math.pi() / 180 * (lon2 - lon1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(:math.pi() / 180 * lat1) *
          :math.cos(:math.pi() / 180 * lat2) *
          :math.sin(dlon / 2) ** 2

    2 * r * :math.asin(:math.sqrt(a))
  end

  def valid_coordinates?({lat, lon}), do: lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180
end

defmodule Logistics.AddressHelpers do
  @moduledoc """
  Address formatting and basic geo-validation utilities shared across
  logistics modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Logistics.GeoUtils  # propagates geo dependency into every caller

      def format_address(%{street: s, city: c, state: st, zip: z, country: co}) do
        "#{s}, #{c}, #{st} #{z}, #{co}"
      end

      def format_address_multiline(%{street: s, city: c, state: st, zip: z, country: co}) do
        "#{s}\n#{c}, #{st} #{z}\n#{co}"
      end

      def normalize_zip(zip) when is_binary(zip) do
        zip
        |> String.replace(~r/[^\w]/, "")
        |> String.upcase()
      end

      def address_complete?(%{street: s, city: c, state: st, zip: z, country: co}) do
        Enum.all?([s, c, st, z, co], &(is_binary(&1) and String.length(&1) > 0))
      end
    end
  end
end

defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Manages the full lifecycle of shipments: creation, status transitions,
  address validation, and delivery confirmation.
  """

  use Logistics.AddressHelpers

  @statuses [:pending, :picked_up, :in_transit, :out_for_delivery, :delivered, :failed]

  def create(params) do
    with :ok <- validate_addresses(params),
         {:ok, shipment} <- build_shipment(params) do
      {:ok, shipment}
    end
  end

  def advance_status(%{status: :delivered}), do: {:error, :already_delivered}
  def advance_status(%{status: :failed}),    do: {:error, :shipment_failed}

  def advance_status(%{status: current} = shipment) do
    idx  = Enum.find_index(@statuses, &(&1 == current))
    next = Enum.at(@statuses, idx + 1)

    {:ok, %{shipment | status: next, updated_at: DateTime.utc_now()}}
  end

  def confirm_delivery(%{status: :out_for_delivery} = shipment, recipient_name) do
    {:ok,
     %{
       shipment
       | status:        :delivered,
         delivered_at:  DateTime.utc_now(),
         signed_by:     recipient_name,
         updated_at:    DateTime.utc_now()
     }}
  end

  def confirm_delivery(_, _), do: {:error, :not_out_for_delivery}

  def render_label(shipment) do
    origin_str = format_address(shipment.origin)
    dest_str   = format_address_multiline(shipment.destination)

    """
    FROM: #{origin_str}
    TO:
    #{dest_str}
    Tracking ID: #{shipment.tracking_number}
    Weight: #{shipment.weight_kg}kg  Class: #{shipment.service_class}
    """
  end

  defp validate_addresses(%{origin: origin, destination: destination}) do
    cond do
      not address_complete?(origin)      -> {:error, {:invalid_address, :origin}}
      not address_complete?(destination) -> {:error, {:invalid_address, :destination}}
      true                               -> :ok
    end
  end

  defp build_shipment(params) do
    shipment = %{
      id:              next_id(),
      tracking_number: generate_tracking(),
      origin:          params.origin,
      destination:     params.destination,
      weight_kg:       params[:weight_kg] || 0.0,
      service_class:   params[:service_class] || :standard,
      status:          :pending,
      created_at:      DateTime.utc_now(),
      updated_at:      DateTime.utc_now(),
      delivered_at:    nil,
      signed_by:       nil
    }

    {:ok, shipment}
  end

  defp next_id, do: :erlang.unique_integer([:positive, :monotonic])

  defp generate_tracking do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16()
    |> then(&"SHP-#{&1}")
  end
end
```
