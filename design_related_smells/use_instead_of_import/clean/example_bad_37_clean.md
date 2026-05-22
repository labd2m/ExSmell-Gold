```elixir
defmodule BinAddressing do
  @address_pattern ~r/^([A-Z]{1,3})-(\d{1,3})-(\d{1,3})$/

  def parse_address(addr) when is_binary(addr) do
    case Regex.run(@address_pattern, addr) do
      [_, aisle, rack, shelf] ->
        {:ok, %{aisle: aisle, rack: String.to_integer(rack), shelf: String.to_integer(shelf)}}
      _ ->
        {:error, "Invalid bin address: #{addr}"}
    end
  end

  def adjacent?(%{aisle: a, rack: r1}, %{aisle: a, rack: r2}), do: abs(r1 - r2) <= 1
  def adjacent?(_, _), do: false

  def sort_by_proximity(bins, %{aisle: a, rack: r, shelf: s}) do
    Enum.sort_by(bins, fn bin ->
      case parse_address(bin.address) do
        {:ok, %{aisle: ba, rack: br, shelf: bs}} ->
          aisle_dist = if ba == a, do: 0, else: 10
          aisle_dist + abs(br - r) + abs(bs - s)
        _ -> 9999
      end
    end)
  end

  def format_address(%{aisle: a, rack: r, shelf: s}) do
    "#{a}-#{String.pad_leading(to_string(r), 3, "0")}-#{String.pad_leading(to_string(s), 3, "0")}"
  end
end

defmodule LocationHelpers do
  defmacro __using__(_opts) do
    quote do
      import BinAddressing

      def zone_for_sku(sku, zone_rules) do
        Enum.find_value(zone_rules, "DEFAULT", fn {pattern, zone} ->
          if String.starts_with?(sku, pattern), do: zone
        end)
      end

      def pick_strategy(order_lines) do
        cond do
          length(order_lines) == 1           -> :single_pick
          Enum.all?(order_lines, & &1.qty <= 5) -> :batch_pick
          true                                -> :zone_pick
        end
      end

      def capacity_used(bin) do
        Float.round(bin.current_units / bin.max_units * 100.0, 1)
      end
    end
  end
end

defmodule WarehouseCoordinator do
  use LocationHelpers

  @zone_rules [{"ELEC-", "A"}, {"FURN-", "C"}, {"FOOD-", "B"}]
  @max_transfer_qty 500
  @low_capacity_pct 20.0

  def allocate_stock(order, available_bins) do
    strategy = pick_strategy(order.lines)

    sorted_bins =
      case parse_address(hd(available_bins).address) do
        {:ok, origin} -> sort_by_proximity(available_bins, origin)
        {:error, _}   -> available_bins
      end

    allocations =
      Enum.map(order.lines, fn line ->
        suitable = Enum.filter(sorted_bins, fn bin ->
          bin.sku == line.sku and bin.current_units >= line.qty
        end)

        case suitable do
          []      -> {:error, line.sku, :insufficient_stock}
          [bin | _] ->
            {:ok, %{
              line_id:   line.id,
              sku:       line.sku,
              qty:       line.qty,
              bin:       bin.address,
              zone:      zone_for_sku(line.sku, @zone_rules),
              strategy:  strategy
            }}
        end
      end)

    errors = Enum.filter(allocations, &match?({:error, _, _}, &1))
    if errors == [],
      do: {:ok, Enum.map(allocations, fn {:ok, a} -> a end)},
      else: {:error, :partial_allocation, errors}
  end

  def transfer(from_address, to_address, qty) when qty > 0 and qty <= @max_transfer_qty do
    with {:ok, from_bin} <- parse_address(from_address),
         {:ok, to_bin}   <- parse_address(to_address) do
      {:ok, %{
        from:       format_address(from_bin),
        to:         format_address(to_bin),
        qty:        qty,
        adjacent:   adjacent?(from_bin, to_bin),
        priority:   if(adjacent?(from_bin, to_bin), do: :normal, else: :planned),
        created_at: DateTime.utc_now()
      }}
    end
  end
  def transfer(_, _, qty) when qty > @max_transfer_qty do
    {:error, "Transfer quantity #{qty} exceeds maximum of #{@max_transfer_qty}"}
  end

  def replenishment_plan(bins) do
    bins
    |> Enum.filter(fn bin -> capacity_used(bin) < @low_capacity_pct end)
    |> Enum.map(fn bin ->
      refill_qty = bin.max_units - bin.current_units
      %{
        bin_address:  bin.address,
        zone:         zone_for_sku(bin.sku, @zone_rules),
        current:      bin.current_units,
        capacity_pct: capacity_used(bin),
        refill_qty:   refill_qty,
        priority:     if(capacity_used(bin) < 10.0, do: :urgent, else: :normal)
      }
    end)
    |> Enum.sort_by(& &1.capacity_pct)
  end

  def bin_report(bins) do
    Enum.map(bins, fn bin ->
      %{
        address:      bin.address,
        sku:          bin.sku,
        capacity_pct: capacity_used(bin),
        zone:         zone_for_sku(bin.sku, @zone_rules),
        status:       if(capacity_used(bin) < @low_capacity_pct, do: :low, else: :ok)
      }
    end)
  end
end
```
