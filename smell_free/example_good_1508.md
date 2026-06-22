```elixir
defmodule Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates for orders based on weight, dimensions,
  destination zone, and carrier service level.

  All monetary amounts are expressed in cents to avoid floating-point
  rounding issues.
  """

  alias Shipping.Parcel
  alias Shipping.Zone

  @type service_level :: :standard | :express | :overnight

  @type rate_result :: %{
          carrier: String.t(),
          service_level: service_level(),
          estimated_days: pos_integer(),
          rate_cents: non_neg_integer()
        }

  @base_rates_cents %{
    standard: 599,
    express: 1199,
    overnight: 2499
  }

  @weight_rate_per_100g_cents 25
  @volume_rate_per_liter_cents 15

  @doc """
  Returns a list of available rate options for a given parcel and destination.

  The list is sorted from cheapest to most expensive.
  """
  @spec calculate(Parcel.t(), Zone.t()) ::
          {:ok, [rate_result()]} | {:error, :unsupported_zone}
  def calculate(%Parcel{} = parcel, %Zone{} = zone) do
    case Zone.supported?(zone) do
      false ->
        {:error, :unsupported_zone}

      true ->
        rates =
          [:standard, :express, :overnight]
          |> Enum.map(&build_rate(&1, parcel, zone))
          |> Enum.sort_by(& &1.rate_cents)

        {:ok, rates}
    end
  end

  @doc """
  Returns the cheapest rate option for the given parcel and destination.
  """
  @spec cheapest_rate(Parcel.t(), Zone.t()) ::
          {:ok, rate_result()} | {:error, :unsupported_zone}
  def cheapest_rate(%Parcel{} = parcel, %Zone{} = zone) do
    with {:ok, [cheapest | _]} <- calculate(parcel, zone) do
      {:ok, cheapest}
    end
  end

  @spec build_rate(service_level(), Parcel.t(), Zone.t()) :: rate_result()
  defp build_rate(level, parcel, zone) do
    base = Map.fetch!(@base_rates_cents, level)
    weight_surcharge = weight_surcharge(parcel.weight_grams)
    volume_surcharge = volume_surcharge(parcel)
    zone_multiplier = Zone.rate_multiplier(zone)
    estimated_days = delivery_days(level, zone)

    raw_rate = (base + weight_surcharge + volume_surcharge) * zone_multiplier
    rate_cents = round(raw_rate)

    %{
      carrier: "DefaultCarrier",
      service_level: level,
      estimated_days: estimated_days,
      rate_cents: rate_cents
    }
  end

  @spec weight_surcharge(non_neg_integer()) :: non_neg_integer()
  defp weight_surcharge(weight_grams) when is_integer(weight_grams) and weight_grams >= 0 do
    units = div(weight_grams, 100)
    units * @weight_rate_per_100g_cents
  end

  @spec volume_surcharge(Parcel.t()) :: non_neg_integer()
  defp volume_surcharge(%Parcel{length_cm: l, width_cm: w, height_cm: h}) do
    volume_liters = l * w * h / 1000.0
    round(volume_liters * @volume_rate_per_liter_cents)
  end

  @spec delivery_days(service_level(), Zone.t()) :: pos_integer()
  defp delivery_days(:standard, zone), do: 3 + zone.distance_tier
  defp delivery_days(:express, zone), do: 1 + zone.distance_tier
  defp delivery_days(:overnight, _zone), do: 1
end
```
