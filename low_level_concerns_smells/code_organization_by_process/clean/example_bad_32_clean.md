```elixir
defmodule Logistics.ShippingCalculator do
  use GenServer

  @moduledoc """
  Calculates shipping costs and estimated delivery windows for parcels
  based on weight, dimensions, and destination zone.
  Used by the fulfilment service during order confirmation.
  """

  @carriers [:standard, :express, :overnight, :economy]

  @base_rates %{
    standard:  %{per_kg: 1.80, handling: 2.50},
    express:   %{per_kg: 3.50, handling: 4.00},
    overnight: %{per_kg: 6.00, handling: 7.50},
    economy:   %{per_kg: 0.95, handling: 1.50}
  }

  @zone_multipliers %{
    domestic:       1.0,
    regional:       1.3,
    international:  2.6,
    remote:         3.8
  }

  @delivery_days %{
    standard:  %{domestic: 5, regional: 7, international: 14, remote: 21},
    express:   %{domestic: 2, regional: 3, international:  7, remote: 10},
    overnight: %{domestic: 1, regional: 2, international:  4, remote:  7},
    economy:   %{domestic: 8, regional: 12, international: 21, remote: 30}
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns a map of `%{carrier => cost_float}` for all available carriers.
  `parcel` must include `:weight_kg` and `:zone` keys.
  """
  def calculate(pid, parcel) do
    GenServer.call(pid, {:calculate, parcel})
  end

  @doc """
  Returns `{carrier, cost}` tuple for the cheapest available carrier.
  """
  def cheapest_option(pid, parcel) do
    GenServer.call(pid, {:cheapest_option, parcel})
  end

  @doc """
  Returns the estimated delivery date for a given carrier and zone.
  `base_date` is a `Date` struct representing the dispatch date.
  """
  def estimated_delivery(pid, carrier, zone, base_date) do
    GenServer.call(pid, {:estimated_delivery, carrier, zone, base_date})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:calculate, %{weight_kg: weight, zone: zone}}, _from, state) do
    results =
      Enum.into(@carriers, %{}, fn carrier ->
        cost = compute_cost(carrier, weight, zone)
        {carrier, cost}
      end)

    {:reply, {:ok, results}, state}
  end

  def handle_call({:cheapest_option, parcel}, _from, state) do
    {:ok, all_costs} = handle_call({:calculate, parcel}, nil, state) |> elem(1) |> then(&{:ok, &1})

    cheapest =
      Enum.min_by(all_costs, fn {_carrier, cost} -> cost end)

    {:reply, {:ok, cheapest}, state}
  end

  def handle_call({:estimated_delivery, carrier, zone, base_date}, _from, state) do
    days = get_in(@delivery_days, [carrier, zone])

    result =
      if days do
        {:ok, Date.add(base_date, days)}
      else
        {:error, :unknown_carrier_or_zone}
      end

    {:reply, result, state}
  end

  ## Private helpers

  defp compute_cost(carrier, weight, zone) do
    %{per_kg: per_kg, handling: handling} = @base_rates[carrier]
    multiplier = Map.get(@zone_multipliers, zone, 1.0)
    Float.round((weight * per_kg + handling) * multiplier, 2)
  end

end
```
