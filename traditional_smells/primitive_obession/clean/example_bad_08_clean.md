```elixir
defmodule Inventory.WeightCalculator do
  @moduledoc """
  Handles weight calculations for inventory items and shipments.
  Supports unit conversions between grams, kilograms, ounces, and
  pounds. Used by the shipping cost estimator and warehouse manifest
  builder.
  """

  require Logger

  @supported_units ~w(g kg oz lb)
  @max_parcel_weight_kg 70.0

  @conversion_to_grams %{
    "g" => 1.0,
    "kg" => 1_000.0,
    "oz" => 28.3495,
    "lb" => 453.592
  }

  @spec convert_weight(float(), String.t(), String.t()) ::
          {:ok, float(), String.t()} | {:error, String.t()}
  def convert_weight(value, from_unit, to_unit) do
    with :ok <- validate_unit(from_unit),
         :ok <- validate_unit(to_unit) do
      grams = value * Map.fetch!(@conversion_to_grams, from_unit)
      converted = Float.round(grams / Map.fetch!(@conversion_to_grams, to_unit), 4)
      {:ok, converted, to_unit}
    end
  end

  @spec calculate_shipping_cost(float(), String.t(), String.t(), String.t()) ::
          {:ok, float()} | {:error, String.t()}
  def calculate_shipping_cost(weight_value, weight_unit, destination_zone, service_class) do
    with {:ok, kg_value, "kg"} <- convert_weight(weight_value, weight_unit, "kg"),
         :ok <- check_weight_limit(kg_value),
         {:ok, base_rate} <- base_rate_for_zone(destination_zone) do
      multiplier = service_multiplier(service_class)
      cost = Float.round(kg_value * base_rate * multiplier, 2)

      Logger.debug(
        "Shipping cost: #{weight_value} #{weight_unit} = #{kg_value} kg, " <>
          "zone #{destination_zone}, #{service_class}: $#{cost}"
      )

      {:ok, cost}
    end
  end

  @spec total_shipment_weight(list(map())) ::
          {:ok, float(), String.t()} | {:error, String.t()}
  def total_shipment_weight([]), do: {:error, "Shipment has no items"}

  def total_shipment_weight(items) do
    results =
      Enum.map(items, fn item ->
        convert_weight(item.weight_value, item.weight_unit, "g")
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors != [] do
      {:error, "Weight conversion failed for some items: #{inspect(errors)}"}
    else
      total_grams =
        results
        |> Enum.map(fn {:ok, v, "g"} -> v end)
        |> Enum.sum()

      {:ok, Float.round(total_grams / 1_000.0, 4), "kg"}
    end
  end

  @spec exceeds_limit?(float(), String.t(), float()) :: boolean()
  def exceeds_limit?(weight_value, weight_unit, limit_kg) do
    case convert_weight(weight_value, weight_unit, "kg") do
      {:ok, kg_value, "kg"} -> kg_value > limit_kg
      {:error, _} -> true
    end
  end

  @spec validate_parcel(float(), String.t()) :: :ok | {:error, String.t()}
  def validate_parcel(weight_value, weight_unit) do
    cond do
      weight_value <= 0.0 ->
        {:error, "Weight must be positive, got #{weight_value} #{weight_unit}"}

      exceeds_limit?(weight_value, weight_unit, @max_parcel_weight_kg) ->
        {:error,
         "Weight #{weight_value} #{weight_unit} exceeds parcel limit of #{@max_parcel_weight_kg} kg"}

      true ->
        :ok
    end
  end

  defp validate_unit(unit) do
    if unit in @supported_units do
      :ok
    else
      {:error,
       "Unsupported weight unit '#{unit}'. Supported: #{Enum.join(@supported_units, ", ")}"}
    end
  end

  defp check_weight_limit(kg_value) do
    if kg_value <= @max_parcel_weight_kg do
      :ok
    else
      {:error, "Weight #{kg_value} kg exceeds maximum parcel weight of #{@max_parcel_weight_kg} kg"}
    end
  end

  defp base_rate_for_zone("DOMESTIC"), do: {:ok, 0.85}
  defp base_rate_for_zone("ZONE_1"), do: {:ok, 1.20}
  defp base_rate_for_zone("ZONE_2"), do: {:ok, 1.75}
  defp base_rate_for_zone("ZONE_3"), do: {:ok, 2.50}
  defp base_rate_for_zone("INTERNATIONAL"), do: {:ok, 4.10}
  defp base_rate_for_zone(zone), do: {:error, "Unknown destination zone: #{zone}"}

  defp service_multiplier("standard"), do: 1.0
  defp service_multiplier("express"), do: 1.5
  defp service_multiplier("overnight"), do: 2.5
  defp service_multiplier(_), do: 1.0
end
```
