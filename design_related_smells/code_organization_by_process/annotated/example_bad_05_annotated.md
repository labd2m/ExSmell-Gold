# Annotated Example 05

- **Smell name:** Code organization by process
- **Expected smell location:** `Logistics.ShippingCostEstimator` module — `GenServer` implementation
- **Affected functions:** `estimate/3`, `dimensional_weight/2`, `zone_surcharge/3`, `fuel_surcharge/3`, `delivery_eta/3`
- **Short explanation:** Shipping cost estimation, dimensional weight calculation, zone surcharges, and ETA projection are all pure computations over numeric inputs and static rule tables. No shared mutable resource is involved, and no I/O is performed at call time. Routing these calculations through a `GenServer` creates an unnecessary sequential bottleneck on the logistics quoting path.

```elixir
defmodule Logistics.ShippingCostEstimator do
  use GenServer

  @moduledoc """
  Estimates shipping costs for parcel and freight shipments.
  Applies dimensional weight rules, zone-based pricing, fuel
  surcharges, and delivery ETA projections.

  Rate tables are injected at startup via the `:rates` option.
  """

  @default_dim_factor 5000.0

  @default_zone_rates %{
    1 => 5.00, 2 => 6.50, 3 => 8.25, 4 => 10.00,
    5 => 13.50, 6 => 17.00, 7 => 21.00, 8 => 27.50
  }

  @default_fuel_rates %{
    standard: 0.125,
    express: 0.175,
    overnight: 0.22
  }

  @eta_days %{
    standard: 5,
    express: 2,
    overnight: 1
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    rates = %{
      zone: Keyword.get(opts, :zone_rates, @default_zone_rates),
      fuel: Keyword.get(opts, :fuel_rates, @default_fuel_rates),
      dim_factor: Keyword.get(opts, :dim_factor, @default_dim_factor)
    }

    GenServer.start_link(__MODULE__, rates, Keyword.drop(opts, [:zone_rates, :fuel_rates, :dim_factor]))
  end

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because every function is a pure computation
  # over numbers and static configuration tables loaded at init time. No state
  # is ever mutated after startup, no external resources are locked, and calls
  # can safely run in parallel. The GenServer bottlenecks all quoting requests
  # through a single mailbox with no benefit.

  @doc """
  Produces a full cost estimate for a shipment.
  `parcel` is `%{weight_kg: w, length_cm: l, width_cm: w, height_cm: h}`.
  `opts` may include `zone:` (1–8) and `service:` (:standard | :express | :overnight).
  """
  def estimate(pid, parcel, opts \\ []) do
    GenServer.call(pid, {:estimate, parcel, opts})
  end

  @doc "Returns the billable (dimensional or actual, whichever is greater) weight in kg."
  def dimensional_weight(pid, %{length_cm: l, width_cm: w, height_cm: h, weight_kg: actual}) do
    GenServer.call(pid, {:dimensional_weight, l, w, h, actual})
  end

  @doc "Returns the base zone rate for a given zone integer."
  def zone_surcharge(pid, base_cost, zone) do
    GenServer.call(pid, {:zone_surcharge, base_cost, zone})
  end

  @doc "Returns the fuel surcharge amount for a given base cost and service level."
  def fuel_surcharge(pid, base_cost, service) do
    GenServer.call(pid, {:fuel_surcharge, base_cost, service})
  end

  @doc "Returns the estimated delivery date as an ISO 8601 string."
  def delivery_eta(pid, ship_date, service) do
    GenServer.call(pid, {:delivery_eta, ship_date, service})
  end

  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(rates), do: {:ok, rates}

  @impl true
  def handle_call({:estimate, parcel, opts}, _from, rates) do
    zone = Keyword.get(opts, :zone, 3)
    service = Keyword.get(opts, :service, :standard)

    billable = do_dimensional_weight(parcel, rates.dim_factor)
    zone_rate = Map.get(rates.zone, zone, 8.25)
    base = billable * zone_rate
    fuel = base * Map.get(rates.fuel, service, 0.125)
    total = Float.round(base + fuel, 2)

    {:reply, {:ok, %{billable_weight_kg: billable, base: Float.round(base, 2),
                     fuel_surcharge: Float.round(fuel, 2), total: total,
                     zone: zone, service: service}}, rates}
  end

  @impl true
  def handle_call({:dimensional_weight, l, w, h, actual}, _from, rates) do
    dim = l * w * h / rates.dim_factor
    billable = max(dim, actual)
    {:reply, {:ok, Float.round(billable, 3)}, rates}
  end

  @impl true
  def handle_call({:zone_surcharge, base_cost, zone}, _from, rates) do
    rate = Map.get(rates.zone, zone, 8.25)
    {:reply, {:ok, Float.round(base_cost * rate / 100, 2)}, rates}
  end

  @impl true
  def handle_call({:fuel_surcharge, base_cost, service}, _from, rates) do
    rate = Map.get(rates.fuel, service, 0.125)
    {:reply, {:ok, Float.round(base_cost * rate, 2)}, rates}
  end

  @impl true
  def handle_call({:delivery_eta, ship_date, service}, _from, rates) do
    days = Map.get(@eta_days, service, 5)
    eta = Date.add(ship_date, days)
    {:reply, {:ok, Date.to_iso8601(eta)}, rates}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_dimensional_weight(%{length_cm: l, width_cm: w, height_cm: h, weight_kg: actual}, dim_factor) do
    dim = l * w * h / dim_factor
    Float.round(max(dim, actual), 3)
  end
end
```
