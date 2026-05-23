```elixir
defmodule ShipmentManager do
  @moduledoc """
  Manages outbound shipment creation and address validation for the logistics platform.
  """

  alias Logistics.{Shipment, Address, CarrierRegistry, TrackingService}

  @supported_countries ~w(US CA GB DE FR AU NZ BR)
  @max_postal_length 10

  def create_shipment(attrs) do
    with {:ok, carrier} <- CarrierRegistry.select(attrs.service_level),
         :ok <- validate_origin(attrs.origin),
         :ok <- validate_destination(attrs.destination),
         {:ok, shipment} <- persist_shipment(attrs, carrier) do
      TrackingService.register(shipment)
      {:ok, shipment}
    end
  end

  defp validate_origin(address) do
    cond do
      is_nil(address.street) or address.street == "" ->
        {:error, :missing_street}

      is_nil(address.city) or address.city == "" ->
        {:error, :missing_city}

      is_nil(address.postal_code) ->
        {:error, :missing_postal_code}

      String.length(String.trim(address.postal_code)) > @max_postal_length ->
        {:error, :postal_code_too_long}

      address.country_code not in @supported_countries ->
        {:error, {:unsupported_country, address.country_code}}

      true ->
        :ok
    end
  end

  defp validate_destination(address) do
    cond do
      is_nil(address.street) or address.street == "" ->
        {:error, :missing_street}

      is_nil(address.city) or address.city == "" ->
        {:error, :missing_city}

      true ->
        :ok
    end
  end

  defp persist_shipment(attrs, carrier) do
    shipment = %Shipment{
      id: Ecto.UUID.generate(),
      origin: attrs.origin,
      destination: attrs.destination,
      carrier_id: carrier.id,
      service_level: attrs.service_level,
      weight_kg: attrs.weight_kg,
      dimensions: attrs.dimensions,
      created_at: DateTime.utc_now(),
      status: :pending
    }

    Logistics.Repo.insert(shipment)
  end

  def validate_addresses(%{origin: origin, destination: destination}) do
    with :ok <- check_address(origin), :ok <- check_address(destination) do
      :ok
    end
  end

  defp check_address(address) do
    cond do
      is_nil(address.street) or address.street == "" ->
        {:error, :missing_street}

      is_nil(address.city) or address.city == "" ->
        {:error, :missing_city}

      is_nil(address.postal_code) ->
        {:error, :missing_postal_code}

      String.length(String.trim(address.postal_code)) > @max_postal_length ->
        {:error, :postal_code_too_long}

      address.country_code not in @supported_countries ->
        {:error, {:unsupported_country, address.country_code}}

      true ->
        :ok
    end
  end

  def bulk_create(shipment_list) do
    results =
      Enum.map(shipment_list, fn attrs ->
        case create_shipment(attrs) do
          {:ok, shipment} -> {:ok, shipment.id}
          {:error, reason} -> {:error, reason}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, id} -> id end)}
    else
      {:partial_failure, results}
    end
  end
end
```
