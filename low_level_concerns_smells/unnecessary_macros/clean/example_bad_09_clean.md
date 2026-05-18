```elixir
defmodule Logistics.ErrorFactory do
  @moduledoc """
  Standardised error map builder for the logistics subsystem.
  Ensures all error responses share a consistent structure.
  """

  defmacro build_error(code, message) do
    quote do
      %{
        error_code: unquote(code),
        message: unquote(message),
        occurred_at: DateTime.utc_now()
      }
    end
  end

  @doc """
  Wraps an error map in the standard `{:error, payload}` tuple.
  """
  @spec wrap(map()) :: {:error, map()}
  def wrap(error_map), do: {:error, error_map}

  @doc """
  Builds a validation error for a specific field.
  """
  @spec validation_error(atom(), String.t()) :: map()
  def validation_error(field, reason) do
    %{
      error_code: :validation_failed,
      field: field,
      message: reason,
      occurred_at: DateTime.utc_now()
    }
  end
end

defmodule Logistics.ShipmentService do
  @moduledoc """
  Handles shipment creation, validation, routing decisions,
  and carrier assignment for outbound logistics operations.
  """

  require Logistics.ErrorFactory

  alias Logistics.ErrorFactory

  @supported_carriers [:fedex, :ups, :dhl, :usps]
  @max_weight_kg 500.0
  @max_volume_cm3 1_000_000

  @doc """
  Validates and creates a shipment record from a request map.
  Returns `{:ok, shipment}` or `{:error, error_map}`.
  """
  @spec create(map()) :: {:ok, map()} | {:error, map()}
  def create(%{weight_kg: weight, volume_cm3: volume, carrier: carrier} = request) do
    with :ok <- validate_weight(weight),
         :ok <- validate_volume(volume),
         :ok <- validate_carrier(carrier) do
      shipment = %{
        id: generate_id(),
        tracking_number: generate_tracking_number(carrier),
        carrier: carrier,
        weight_kg: weight,
        volume_cm3: volume,
        origin: request[:origin],
        destination: request[:destination],
        created_at: DateTime.utc_now(),
        status: :pending
      }

      {:ok, shipment}
    end
  end

  defp validate_weight(weight) when weight > 0 and weight <= @max_weight_kg, do: :ok

  defp validate_weight(weight) when weight <= 0 do
    ErrorFactory.wrap(ErrorFactory.build_error(:invalid_weight, "Weight must be positive; got #{weight}"))
  end

  defp validate_weight(weight) do
    ErrorFactory.wrap(
      ErrorFactory.build_error(:weight_exceeded, "Weight #{weight}kg exceeds limit of #{@max_weight_kg}kg")
    )
  end

  defp validate_volume(volume) when volume > 0 and volume <= @max_volume_cm3, do: :ok

  defp validate_volume(_volume) do
    ErrorFactory.wrap(ErrorFactory.build_error(:volume_exceeded, "Volume exceeds maximum allowed"))
  end

  defp validate_carrier(carrier) when carrier in @supported_carriers, do: :ok

  defp validate_carrier(carrier) do
    ErrorFactory.wrap(
      ErrorFactory.build_error(:unsupported_carrier, "Carrier #{carrier} is not supported")
    )
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_tracking_number(carrier) do
    prefix = carrier |> Atom.to_string() |> String.upcase() |> String.slice(0, 3)
    suffix = :rand.uniform(999_999_999) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{prefix}#{suffix}"
  end

  @doc """
  Lists all shipments filtered by status.
  """
  @spec list_by_status(list(map()), atom()) :: list(map())
  def list_by_status(shipments, status) do
    Enum.filter(shipments, &(&1.status == status))
  end
end
```
