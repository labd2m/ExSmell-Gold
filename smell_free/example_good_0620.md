```elixir
defmodule Logistics.CarrierSelector do
  @moduledoc """
  Selects the optimal shipping carrier for a parcel based on declared
  carrier preferences, weight tiers, and destination zone. Each carrier
  definition specifies the zones it services, its weight ceiling, and a
  cost-per-kg rate. The selector is a pure module: no process state, no
  IO, no side effects.
  """

  @type zone :: String.t()
  @type carrier_id :: atom()

  @type carrier_def :: %{
          id: carrier_id(),
          name: String.t(),
          zones: [zone()],
          max_weight_grams: pos_integer(),
          base_rate_cents: non_neg_integer(),
          rate_per_kg_cents: non_neg_integer(),
          priority: non_neg_integer()
        }

  @type parcel :: %{
          weight_grams: pos_integer(),
          destination_zone: zone()
        }

  @type selection :: %{
          carrier: carrier_def(),
          estimated_cost_cents: non_neg_integer()
        }

  @doc """
  Returns the best carrier for `parcel` from `carriers`, choosing the
  lowest-cost eligible option. Ties are broken by `priority` ascending.
  Returns `{:error, :no_eligible_carrier}` when no carrier covers the
  zone or weight.
  """
  @spec select([carrier_def()], parcel()) ::
          {:ok, selection()} | {:error, :no_eligible_carrier}
  def select(carriers, %{weight_grams: weight, destination_zone: zone} = _parcel)
      when is_list(carriers) and is_integer(weight) and is_binary(zone) do
    eligible =
      carriers
      |> Enum.filter(&eligible?(&1, weight, zone))
      |> Enum.map(fn c -> {c, estimate_cost(c, weight)} end)
      |> Enum.sort_by(fn {c, cost} -> {cost, c.priority} end)

    case eligible do
      [] -> {:error, :no_eligible_carrier}
      [{carrier, cost} | _] -> {:ok, %{carrier: carrier, estimated_cost_cents: cost}}
    end
  end

  @doc "Returns all carriers that can service the given zone and weight."
  @spec eligible_carriers([carrier_def()], pos_integer(), zone()) :: [carrier_def()]
  def eligible_carriers(carriers, weight, zone)
      when is_list(carriers) and is_integer(weight) and is_binary(zone) do
    Enum.filter(carriers, &eligible?(&1, weight, zone))
  end

  @doc "Estimates the shipping cost in cents for a carrier and parcel weight."
  @spec estimate_cost(carrier_def(), pos_integer()) :: non_neg_integer()
  def estimate_cost(%{base_rate_cents: base, rate_per_kg_cents: rate}, weight_grams) do
    kg = weight_grams / 1_000
    base + round(kg * rate)
  end

  @doc """
  Compares two carrier selections and returns `:cheaper`, `:dearer`, or
  `:same` from the perspective of the first argument.
  """
  @spec compare(selection(), selection()) :: :cheaper | :dearer | :same
  def compare(%{estimated_cost_cents: a}, %{estimated_cost_cents: b}) do
    cond do
      a < b -> :cheaper
      a > b -> :dearer
      true -> :same
    end
  end

  defp eligible?(%{zones: zones, max_weight_grams: max_w}, weight, zone) do
    zone in zones and weight <= max_w
  end
end
```
