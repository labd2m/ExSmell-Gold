```elixir
defmodule Warehouse.ZonePolicy do
  @moduledoc """
  Defines environmental tolerances and permitted product categories for
  each warehouse zone type to ensure storage compliance and product safety.
  """


  @spec temperature_range(atom()) :: {float(), float()}
  def temperature_range(:dry),          do: {15.0, 25.0}
  def temperature_range(:refrigerated), do: {2.0, 8.0}
  def temperature_range(:frozen),       do: {-25.0, -18.0}

  @spec humidity_range(atom()) :: {float(), float()}
  def humidity_range(:dry),          do: {30.0, 60.0}
  def humidity_range(:refrigerated), do: {85.0, 95.0}
  def humidity_range(:frozen),       do: {70.0, 90.0}

  @spec compatible_categories(atom()) :: [atom()]
  def compatible_categories(:dry) do
    [:dry_goods, :electronics, :clothing, :household, :books]
  end

  def compatible_categories(:refrigerated) do
    [:fresh_produce, :dairy, :beverages, :fresh_meat, :pharmaceuticals]
  end

  def compatible_categories(:frozen) do
    [:frozen_food, :ice_cream, :frozen_meat, :frozen_seafood]
  end


  def zone_suitable_for?(zone_type, product_category) do
    product_category in compatible_categories(zone_type)
  end

  def suggest_zone(product) do
    [:dry, :refrigerated, :frozen]
    |> Enum.find(fn zone -> zone_suitable_for?(zone, product.category) end)
  end
end

defmodule Warehouse.EnvironmentMonitor do
  @moduledoc """
  Monitors warehouse zone environmental conditions, triggering alerts
  when temperature or humidity readings fall outside safe operating ranges.
  """


  @spec alert_on_breach?(atom()) :: boolean()
  def alert_on_breach?(:dry),          do: true
  def alert_on_breach?(:refrigerated), do: true
  def alert_on_breach?(:frozen),       do: true

  @spec check_interval_minutes(atom()) :: pos_integer()
  def check_interval_minutes(:dry),          do: 60
  def check_interval_minutes(:refrigerated), do: 15
  def check_interval_minutes(:frozen),       do: 10


  def evaluate_reading(zone, reading) do
    {t_min, t_max} = Warehouse.ZonePolicy.temperature_range(zone.type)
    {h_min, h_max} = Warehouse.ZonePolicy.humidity_range(zone.type)

    temp_ok = reading.temperature >= t_min and reading.temperature <= t_max
    hum_ok  = reading.humidity    >= h_min and reading.humidity    <= h_max

    cond do
      not temp_ok and alert_on_breach?(zone.type) ->
        {:alert, :temperature_breach, %{zone: zone.id, reading: reading.temperature,
                                         safe: {t_min, t_max}}}

      not hum_ok and alert_on_breach?(zone.type) ->
        {:alert, :humidity_breach, %{zone: zone.id, reading: reading.humidity,
                                      safe: {h_min, h_max}}}

      true -> :ok
    end
  end
end

defmodule Warehouse.PickingEngine do
  @moduledoc """
  Determines the optimal picking strategy and replenishment trigger points
  for each storage zone to maximise throughput and minimise spoilage.
  """


  @spec picking_strategy(atom()) :: atom()
  def picking_strategy(:dry),          do: :fifo
  def picking_strategy(:refrigerated), do: :fefo
  def picking_strategy(:frozen),       do: :fefo

  @spec replenishment_trigger_pct(atom()) :: float()
  def replenishment_trigger_pct(:dry),          do: 0.20
  def replenishment_trigger_pct(:refrigerated), do: 0.30
  def replenishment_trigger_pct(:frozen),       do: 0.25


  def pick_order(zone, order_lines) do
    strategy = picking_strategy(zone.type)

    order_lines
    |> Enum.flat_map(fn line ->
      zone.stock
      |> Enum.filter(& &1.sku == line.sku)
      |> sort_by_strategy(strategy)
      |> Enum.take(line.quantity)
    end)
  end

  def needs_replenishment?(zone) do
    trigger = replenishment_trigger_pct(zone.type)
    zone.current_fill_level < trigger
  end

  defp sort_by_strategy(units, :fifo), do: Enum.sort_by(units, & &1.received_at, DateTime)
  defp sort_by_strategy(units, :fefo), do: Enum.sort_by(units, & &1.expiry_date, Date)
end
```
