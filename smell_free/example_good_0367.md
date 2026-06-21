```elixir
defmodule Warehouse.PickListBuilder do
  @moduledoc """
  Builds optimised pick lists for warehouse fulfilment orders. Given a
  list of order line items and a bin location map, the builder groups
  picks by aisle, sorts within each aisle by bin sequence, and returns
  an ordered walk list that minimises travel distance. All logic is
  pure and operates on plain maps.
  """

  @type bin_id :: String.t()
  @type aisle :: String.t()
  @type bin_location :: %{bin_id: bin_id(), aisle: aisle(), sequence: non_neg_integer()}
  @type pick_item :: %{
          sku: String.t(),
          quantity: pos_integer(),
          bin_id: bin_id(),
          order_id: String.t()
        }
  @type pick_step :: %{
          bin_id: bin_id(),
          aisle: aisle(),
          sequence: non_neg_integer(),
          picks: [pick_item()]
        }

  @doc """
  Builds an ordered pick list from `items`, using `bin_map` (keyed by
  `bin_id`) to resolve locations. Items with no matching bin entry are
  collected separately for operator review.
  """
  @spec build([pick_item()], %{bin_id() => bin_location()}) ::
          %{pick_list: [pick_step()], unresolved: [pick_item()]}
  def build(items, bin_map) when is_list(items) and is_map(bin_map) do
    {resolvable, unresolved} = Enum.split_with(items, fn i -> Map.has_key?(bin_map, i.bin_id) end)

    pick_list =
      resolvable
      |> Enum.group_by(& &1.bin_id)
      |> Enum.map(fn {bin_id, picks} ->
        location = Map.fetch!(bin_map, bin_id)
        %{bin_id: bin_id, aisle: location.aisle, sequence: location.sequence, picks: picks}
      end)
      |> Enum.sort_by(fn step -> {step.aisle, step.sequence} end)

    %{pick_list: pick_list, unresolved: unresolved}
  end

  @doc "Returns the total number of units across all pick steps."
  @spec total_units([pick_step()]) :: non_neg_integer()
  def total_units(pick_list) when is_list(pick_list) do
    pick_list
    |> Enum.flat_map(& &1.picks)
    |> Enum.sum_by(& &1.quantity)
  end

  @doc "Groups pick steps by aisle, returning a map of aisle to step list."
  @spec by_aisle([pick_step()]) :: %{aisle() => [pick_step()]}
  def by_aisle(pick_list) when is_list(pick_list) do
    Enum.group_by(pick_list, & &1.aisle)
  end

  @doc "Returns pick steps that require more than `threshold` units in a single bin."
  @spec high_volume_picks([pick_step()], pos_integer()) :: [pick_step()]
  def high_volume_picks(pick_list, threshold)
      when is_list(pick_list) and is_integer(threshold) and threshold > 0 do
    Enum.filter(pick_list, fn step ->
      total = Enum.sum_by(step.picks, & &1.quantity)
      total > threshold
    end)
  end

  @doc "Merges pick steps that share a bin ID, summing quantities per SKU."
  @spec consolidate([pick_step()]) :: [pick_step()]
  def consolidate(pick_list) when is_list(pick_list) do
    pick_list
    |> Enum.group_by(& &1.bin_id)
    |> Enum.map(fn {bin_id, steps} ->
      merged_picks = merge_picks(Enum.flat_map(steps, & &1.picks))
      hd(steps) |> Map.put(:picks, merged_picks)
    end)
    |> Enum.sort_by(fn s -> {s.aisle, s.sequence} end)
  end

  defp merge_picks(picks) do
    picks
    |> Enum.group_by(& &1.sku)
    |> Enum.map(fn {sku, grouped} ->
      total = Enum.sum_by(grouped, & &1.quantity)
      hd(grouped) |> Map.put(:quantity, total)
    end)
  end
end
```
