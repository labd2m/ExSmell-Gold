```elixir
defmodule Logistics.DeliveryDistanceEstimator do
  @moduledoc """
  Estimates delivery costs and feasibility based on route distances.
  Integrates with the carrier rate table for zone-based pricing and
  handles both same-day and standard delivery eligibility checks.
  """

  require Logger

  @free_delivery_threshold_km 5.0
  @same_day_max_km 30.0
  @standard_max_km 500.0

  @carrier_rate_table [
    %{min_km: 0.0, max_km: 5.0, rate_per_km: 0.00, base_fee: 0.00},
    %{min_km: 5.0, max_km: 15.0, rate_per_km: 0.45, base_fee: 2.50},
    %{min_km: 15.0, max_km: 50.0, rate_per_km: 0.38, base_fee: 5.00},
    %{min_km: 50.0, max_km: 150.0, rate_per_km: 0.30, base_fee: 12.00},
    %{min_km: 150.0, max_km: 500.0, rate_per_km: 0.22, base_fee: 25.00}
  ]

  @spec estimate_delivery_cost(float(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def estimate_delivery_cost(distance_km, service_type, carrier_id)
      when is_float(distance_km) and is_binary(service_type) and is_binary(carrier_id) do
    with :ok <- validate_distance(distance_km),
         :ok <- validate_service_feasibility(distance_km, service_type),
         {:ok, rate_bracket} <- find_rate_bracket(distance_km) do
      cost = Float.round(rate_bracket.base_fee + distance_km * rate_bracket.rate_per_km, 2)
      multiplier = service_multiplier(service_type)
      final_cost = Float.round(cost * multiplier, 2)

      Logger.info(
        "Delivery cost estimated: #{distance_km} km, #{service_type} via #{carrier_id} = $#{final_cost}"
      )

      {:ok,
       %{
         distance_km: distance_km,
         service_type: service_type,
         carrier_id: carrier_id,
         base_cost: cost,
         final_cost: final_cost,
         rate_per_km: rate_bracket.rate_per_km,
         free_delivery: within_free_delivery_radius?(distance_km)
       }}
    end
  end

  @spec within_free_delivery_radius?(float()) :: boolean()
  def within_free_delivery_radius?(distance_km) when is_float(distance_km) do
    distance_km <= @free_delivery_threshold_km
  end

  @spec add_distances(float(), float()) :: float()
  def add_distances(distance_a_km, distance_b_km)
      when is_float(distance_a_km) and is_float(distance_b_km) do
    Float.round(distance_a_km + distance_b_km, 3)
  end

  @spec convert_distance(float(), String.t(), String.t()) ::
          {:ok, float()} | {:error, String.t()}
  def convert_distance(value, from_unit, to_unit) do
    km_value =
      case from_unit do
        "km" -> value
        "mi" -> value * 1.60934
        "m" -> value / 1_000.0
        other -> {:error, "Unknown unit '#{other}'"}
      end

    case km_value do
      {:error, _} = err ->
        err

      km ->
        result =
          case to_unit do
            "km" -> km
            "mi" -> km / 1.60934
            "m" -> km * 1_000.0
            other -> {:error, "Unknown unit '#{other}'"}
          end

        case result do
          {:error, _} = err -> err
          converted -> {:ok, Float.round(converted, 4)}
        end
    end
  end

  @spec total_route_distance(list(float())) :: float()
  def total_route_distance(segment_distances_km) when is_list(segment_distances_km) do
    segment_distances_km
    |> Enum.sum()
    |> Float.round(3)
  end

  @spec eligible_for_same_day?(float()) :: boolean()
  def eligible_for_same_day?(distance_km) when is_float(distance_km) do
    distance_km <= @same_day_max_km
  end

  defp validate_distance(distance_km) do
    cond do
      distance_km < 0.0 ->
        {:error, "Distance cannot be negative: #{distance_km} km"}

      distance_km > @standard_max_km ->
        {:error,
         "Distance #{distance_km} km exceeds maximum serviceable range of #{@standard_max_km} km"}

      true ->
        :ok
    end
  end

  defp validate_service_feasibility(distance_km, "same_day") do
    if distance_km <= @same_day_max_km do
      :ok
    else
      {:error,
       "Same-day delivery not available for #{distance_km} km (max: #{@same_day_max_km} km)"}
    end
  end

  defp validate_service_feasibility(_distance_km, _service_type), do: :ok

  defp find_rate_bracket(distance_km) do
    case Enum.find(@carrier_rate_table, fn b ->
           distance_km >= b.min_km and distance_km < b.max_km
         end) do
      nil -> {:error, "No rate bracket found for distance #{distance_km} km"}
      bracket -> {:ok, bracket}
    end
  end

  defp service_multiplier("same_day"), do: 2.0
  defp service_multiplier("express"), do: 1.5
  defp service_multiplier("standard"), do: 1.0
  defp service_multiplier(_), do: 1.0
end
```
