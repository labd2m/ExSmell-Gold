```elixir
defmodule MyApp.Warehouse.PutawayEngine do
  @moduledoc """
  Suggests optimal bin locations for inbound goods during the warehouse
  putaway process. Uses slotting rules, current bin utilisation, and
  product affinity scores to rank candidate locations.
  """

  alias MyApp.Warehouse.BinRegistry
  alias MyApp.Warehouse.SlottingRules
  alias MyApp.Warehouse.AffinityMatrix
  alias MyApp.Warehouse.CapacityChecker
  alias MyApp.Warehouse.PutawayPlan

  @candidate_limit 10
  @min_score 0.3

  defstruct [
    :sku, :quantity, :zone,
    :bin_code, :score, :rationale
  ]

  def inbound_item(sku, quantity, attrs \\ %{}) do
    %{
      sku: sku,
      quantity: quantity,
      weight_kg: attrs[:weight_kg],
      volume_cm3: attrs[:volume_cm3],
      hazmat: Map.get(attrs, :hazmat, false),
      requires_refrigeration: Map.get(attrs, :requires_refrigeration, false)
    }
  end

  def suggest(item, opts \\ []) when is_list(opts) do
    output = Keyword.get(opts, :output, :best)
    zone = Keyword.get(opts, :zone, :any)
    limit = Keyword.get(opts, :limit, @candidate_limit)
    min_score = Keyword.get(opts, :min_score, @min_score)

    candidates =
      BinRegistry.available_bins(zone: zone, limit: limit * 2)
      |> Enum.filter(&CapacityChecker.fits?(&1, item))
      |> Enum.map(fn bin ->
        slotting_score = SlottingRules.score(bin, item)
        affinity_score = AffinityMatrix.score(bin.code, item.sku)
        combined = slotting_score * 0.6 + affinity_score * 0.4
        {bin, combined}
      end)
      |> Enum.filter(fn {_bin, score} -> score >= min_score end)
      |> Enum.sort_by(fn {_bin, score} -> score end, :desc)
      |> Enum.take(limit)

    case candidates do
      [] ->
        {:error, :no_suitable_bin}

      [{top_bin, top_score} | _] = ranked ->
        case output do
          :best ->
            top_bin.code

          :ranked ->
            Enum.map(ranked, fn {bin, score} -> {bin.code, score} end)

          :plan ->
            %PutawayPlan{
              sku: item.sku,
              quantity: item.quantity,
              primary_bin: top_bin.code,
              primary_score: top_score,
              alternatives: Enum.map(tl(ranked), fn {b, s} -> {b.code, s} end),
              zone: top_bin.zone,
              aisle: top_bin.aisle,
              equipment_required: equipment_for(item),
              estimated_minutes: estimate_time(top_bin),
              generated_at: DateTime.utc_now()
            }
        end
    end
  end

  def confirm_putaway(bin_code, sku, quantity) do
    BinRegistry.record_stock(bin_code, sku, quantity)
  end

  def override_bin(bin_code, item, reason) do
    %__MODULE__{
      sku: item.sku,
      quantity: item.quantity,
      zone: nil,
      bin_code: bin_code,
      score: 0.0,
      rationale: {:manual_override, reason}
    }
  end

  defp equipment_for(%{weight_kg: w}) when w > 50, do: :forklift
  defp equipment_for(%{volume_cm3: v}) when v > 500_000, do: :pallet_jack
  defp equipment_for(_), do: :manual

  defp estimate_time(bin) do
    base = 5
    aisle_penalty = (bin.aisle_number || 1) * 0.5
    Float.round(base + aisle_penalty, 1)
  end
end
```
