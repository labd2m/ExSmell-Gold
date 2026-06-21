```elixir
defmodule MyApp.Warehouse.PickListGenerator do
  @moduledoc """
  Generates optimised pick lists for warehouse fulfilment by grouping
  order line items by storage zone and sorting within each zone by bin
  location to minimise picker travel distance.

  Pick lists are pure data transformations: no process, database, or
  network interaction occurs here. The input is a list of order lines
  already enriched with bin location data from the inventory system.
  """

  @type bin_location :: %{
          required(:zone) => String.t(),
          required(:aisle) => String.t(),
          required(:shelf) => pos_integer(),
          required(:position) => pos_integer()
        }

  @type order_line :: %{
          required(:order_id) => String.t(),
          required(:sku) => String.t(),
          required(:quantity) => pos_integer(),
          required(:bin) => bin_location()
        }

  @type pick_item :: %{
          sku: String.t(),
          quantity: pos_integer(),
          order_id: String.t(),
          zone: String.t(),
          aisle: String.t(),
          shelf: pos_integer(),
          position: pos_integer()
        }

  @type zone_group :: %{
          zone: String.t(),
          items: [pick_item()],
          total_units: non_neg_integer()
        }

  @doc """
  Generates an ordered pick list from `order_lines`. Lines are grouped
  by storage zone and sorted within each zone by aisle, shelf, and
  position to create an efficient travel path. Returns zone groups in
  alphabetical zone order.
  """
  @spec generate([order_line()]) :: [zone_group()]
  def generate(order_lines) when is_list(order_lines) do
    order_lines
    |> Enum.map(&to_pick_item/1)
    |> Enum.group_by(& &1.zone)
    |> Enum.map(fn {zone, items} ->
      sorted = Enum.sort_by(items, &{&1.aisle, &1.shelf, &1.position})
      %{zone: zone, items: sorted, total_units: Enum.sum_by(sorted, & &1.quantity)}
    end)
    |> Enum.sort_by(& &1.zone)
  end

  @doc """
  Consolidates pick items with the same SKU and bin location into a
  single item with summed quantity. Useful when multiple orders require
  the same item from the same bin.
  """
  @spec consolidate([pick_item()]) :: [pick_item()]
  def consolidate(items) when is_list(items) do
    items
    |> Enum.group_by(&{&1.sku, &1.zone, &1.aisle, &1.shelf, &1.position})
    |> Enum.map(fn {{sku, zone, aisle, shelf, position}, group} ->
      %{
        sku: sku,
        quantity: Enum.sum_by(group, & &1.quantity),
        order_id: group |> Enum.map(& &1.order_id) |> Enum.join(","),
        zone: zone,
        aisle: aisle,
        shelf: shelf,
        position: position
      }
    end)
    |> Enum.sort_by(&{&1.aisle, &1.shelf, &1.position})
  end

  @doc "Returns the total number of units to be picked across all zones."
  @spec total_units([zone_group()]) :: non_neg_integer()
  def total_units(zone_groups), do: Enum.sum_by(zone_groups, & &1.total_units)

  @spec to_pick_item(order_line()) :: pick_item()
  defp to_pick_item(line) do
    %{
      sku: line.sku,
      quantity: line.quantity,
      order_id: line.order_id,
      zone: line.bin.zone,
      aisle: line.bin.aisle,
      shelf: line.bin.shelf,
      position: line.bin.position
    }
  end
end
```
