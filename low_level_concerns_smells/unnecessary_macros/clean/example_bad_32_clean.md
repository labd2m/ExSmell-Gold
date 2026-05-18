```elixir
defmodule Logistics.EtaCalculator do
  @moduledoc """
  Estimates delivery dates for shipments based on carrier service levels,
  dispatch dates, regional holidays, and warehouse cut-off times.
  """

  @business_days ~w(monday tuesday wednesday thursday friday)a
  @public_holidays [
    ~D[2025-01-01],
    ~D[2025-04-18],
    ~D[2025-12-25],
    ~D[2025-12-26]
  ]

  defmacro compute_eta(dispatch_date, transit_days) do
    quote do
      base_date = unquote(dispatch_date)
      days_to_add = unquote(transit_days)
      holidays = unquote(@public_holidays)
      business = unquote(@business_days)

      Enum.reduce_while(1..365, {base_date, 0}, fn _, {current, added} ->
        if added >= days_to_add do
          {:halt, current}
        else
          next = Date.add(current, 1)
          dow = Date.day_of_week(next) |> day_name()

          if dow in business and next not in holidays do
            {:cont, {next, added + 1}}
          else
            {:cont, {next, added}}
          end
        end
      end)
      |> case do
        {date, _} -> date
        other -> other
      end
    end
  end

  def day_name(1), do: :monday
  def day_name(2), do: :tuesday
  def day_name(3), do: :wednesday
  def day_name(4), do: :thursday
  def day_name(5), do: :friday
  def day_name(6), do: :saturday
  def day_name(7), do: :sunday

  def service_level_days(:express), do: 1
  def service_level_days(:standard), do: 5
  def service_level_days(:economy), do: 10
  def service_level_days(_), do: 7

  def estimate(shipment) do
    require Logistics.EtaCalculator

    transit = service_level_days(shipment.service_level)
    dispatch = shipment.dispatch_date || Date.utc_today()

    eta = Logistics.EtaCalculator.compute_eta(dispatch, transit)

    %{
      shipment_id: shipment.id,
      carrier: shipment.carrier,
      service_level: shipment.service_level,
      dispatch_date: dispatch,
      estimated_delivery: eta,
      transit_days: transit
    }
  end

  def estimate_batch(shipments) do
    Enum.map(shipments, &estimate/1)
  end

  def is_late?(shipment) do
    require Logistics.EtaCalculator

    transit = service_level_days(shipment.service_level)
    eta = Logistics.EtaCalculator.compute_eta(shipment.dispatch_date, transit)
    Date.compare(Date.utc_today(), eta) == :gt and shipment.status != :delivered
  end

  def overdue_shipments(shipments) do
    Enum.filter(shipments, &is_late?/1)
  end

  def days_until_delivery(shipment) do
    require Logistics.EtaCalculator

    transit = service_level_days(shipment.service_level)
    eta = Logistics.EtaCalculator.compute_eta(shipment.dispatch_date, transit)
    Date.diff(eta, Date.utc_today())
  end
end
```
