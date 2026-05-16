# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Warehouse.PickListGenerator.generate/2`, where optional pick strategy fields are accessed dynamically
- **Affected function(s):** `generate/2`
- **Short explanation:** The function reads `:zone_restriction`, `:batch_size`, and `:priority_sku_prefix` from the strategy map using bracket access. Absent keys return `nil`, so zone filtering is silently bypassed, batching defaults to `nil` (causing a crash in `Enum.chunk_every/2`), and SKU prioritisation is disabled without any indication.

```elixir
defmodule Warehouse.PickListGenerator do
  @moduledoc """
  Generates optimised pick lists for warehouse fulfilment operations.
  Supports zone-restricted picking, batch picking, SKU priority ordering,
  and weight-based bin assignment for multi-carrier outbound shipments.
  """

  require Logger

  @default_batch_size    20
  @max_weight_per_picker 30.0

  @type pick_item :: %{
          order_id: String.t(),
          sku: String.t(),
          quantity: pos_integer(),
          bin_location: String.t(),
          zone: String.t(),
          weight_kg: float()
        }

  @type pick_strategy :: %{
          warehouse_id: String.t(),
          optional(:zone_restriction) => String.t(),
          optional(:batch_size) => pos_integer(),
          optional(:priority_sku_prefix) => String.t(),
          optional(:max_weight_kg) => float()
        }

  @spec generate([pick_item()], pick_strategy()) ::
          {:ok, [map()]} | {:error, String.t()}
  def generate([], _strategy), do: {:error, "no pick items provided"}

  def generate(items, strategy) do
    with {:ok, filtered}  <- apply_zone_filter(items, strategy),
         {:ok, sorted}    <- sort_items(filtered, strategy),
         {:ok, batches}   <- split_into_batches(sorted, strategy) do
      pick_lists = Enum.with_index(batches, 1) |> Enum.map(&build_pick_list(&1, strategy))
      Logger.info("Generated #{length(pick_lists)} pick list(s) for warehouse #{strategy.warehouse_id}")
      {:ok, pick_lists}
    end
  end

  defp apply_zone_filter(items, strategy) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `strategy[:zone_restriction]`,
    # `strategy[:batch_size]`, and `strategy[:priority_sku_prefix]` use dynamic
    # bracket access on a plain map. When `:zone_restriction` is absent, `nil`
    # is returned and the filter is silently skipped — items from all zones are
    # included regardless of intent. When `:batch_size` is absent, `nil` is
    # passed to `Enum.chunk_every/2`, which raises an ArgumentError at runtime.
    # The code cannot distinguish a deliberately unrestricted strategy from one
    # where the zone field was accidentally omitted.
    zone_restriction    = strategy[:zone_restriction]
    batch_size          = strategy[:batch_size]
    priority_sku_prefix = strategy[:priority_sku_prefix]
    # VALIDATION: SMELL END

    filtered =
      if zone_restriction do
        Enum.filter(items, &(&1.zone == zone_restriction))
      else
        items
      end

    if filtered == [] do
      {:error, "no items match zone restriction '#{zone_restriction}'"}
    else
      {:ok, {filtered, batch_size, priority_sku_prefix}}
    end
  end

  defp sort_items({items, batch_size, priority_sku_prefix}, _strategy) do
    sorted =
      items
      |> Enum.sort_by(fn item ->
        priority = if priority_sku_prefix && String.starts_with?(item.sku, priority_sku_prefix), do: 0, else: 1
        {priority, item.zone, item.bin_location}
      end)

    {:ok, {sorted, batch_size}}
  end

  defp split_into_batches({items, batch_size}, _strategy) do
    effective_batch = batch_size || @default_batch_size
    {:ok, Enum.chunk_every(items, effective_batch)}
  end

  defp build_pick_list({batch, index}, strategy) do
    total_weight = Enum.reduce(batch, 0.0, fn item, acc -> acc + item.weight_kg * item.quantity end)
    max_weight   = strategy[:max_weight_kg] || @max_weight_per_picker

    %{
      pick_list_id:  "PL-#{strategy.warehouse_id}-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
      warehouse_id:  strategy.warehouse_id,
      sequence:      index,
      item_count:    length(batch),
      total_weight:  Float.round(total_weight, 2),
      overweight:    total_weight > max_weight,
      items:         Enum.map(batch, &format_pick_line/1),
      generated_at:  DateTime.utc_now()
    }
  end

  defp format_pick_line(item) do
    %{
      order_id:     item.order_id,
      sku:          item.sku,
      bin:          item.bin_location,
      zone:         item.zone,
      quantity:     item.quantity,
      weight_kg:    item.weight_kg
    }
  end

  @spec summary([map()]) :: map()
  def summary(pick_lists) do
    total_items   = Enum.sum(Enum.map(pick_lists, & &1.item_count))
    total_weight  = Enum.sum(Enum.map(pick_lists, & &1.total_weight))
    overweight    = Enum.count(pick_lists, & &1.overweight)

    %{
      total_lists:    length(pick_lists),
      total_items:    total_items,
      total_weight:   Float.round(total_weight, 2),
      overweight_lists: overweight
    }
  end
end
```
