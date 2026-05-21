# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Logistics.ShippingCalculator` module
- **Affected function(s)**: `estimate/3`, `cheapest_option/2`, `transit_days/3`, `available_services/2`
- **Short explanation**: Shipping cost and transit time estimation is purely deterministic math on input parameters and a static carrier-rate table. The `GenServer` state is never modified after startup. All shipping calculation calls serialize through one process, creating a bottleneck in order checkout flows where these estimates are needed for every cart.

## Code

```elixir
defmodule Logistics.ShippingCalculator do
  use GenServer

  @moduledoc """
  Estimates shipping costs and transit times for domestic and international
  parcels. Consumed by the checkout pipeline and the order management dashboard.
  """

  @carriers %{
    "standard" => %{
      base_rate: 5.99,
      per_kg: 1.20,
      per_km: 0.003,
      transit_days: 5,
      max_weight_kg: 30.0
    },
    "express" => %{
      base_rate: 14.99,
      per_kg: 2.50,
      per_km: 0.005,
      transit_days: 2,
      max_weight_kg: 20.0
    },
    "overnight" => %{
      base_rate: 29.99,
      per_kg: 4.00,
      per_km: 0.008,
      transit_days: 1,
      max_weight_kg: 10.0
    },
    "economy" => %{
      base_rate: 2.99,
      per_kg: 0.80,
      per_km: 0.001,
      transit_days: 10,
      max_weight_kg: 50.0
    }
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because ShippingCalculator uses GenServer purely as
  # VALIDATION: a code organization mechanism. The process holds no mutable state;
  # VALIDATION: the carrier table is a compile-time module attribute. All four
  # VALIDATION: public operations are deterministic computations on their arguments.
  # VALIDATION: Every checkout page load serializes through this single process
  # VALIDATION: despite the work being embarrassingly parallel and stateless.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Estimates the shipping cost for a parcel using a specific carrier service.
  `parcel` is a map with `:weight_kg` and `:distance_km`.
  """
  def estimate(pid, service, parcel) do
    GenServer.call(pid, {:estimate, service, parcel})
  end

  @doc """
  Returns the cheapest available shipping option for the given parcel.
  """
  def cheapest_option(pid, parcel) do
    GenServer.call(pid, {:cheapest_option, parcel})
  end

  @doc """
  Returns the expected transit time in days for a service and distance.
  """
  def transit_days(pid, service, distance_km) do
    GenServer.call(pid, {:transit_days, service, distance_km})
  end

  @doc """
  Returns all services that can handle the given parcel.
  """
  def available_services(pid, parcel) do
    GenServer.call(pid, {:available_services, parcel})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:estimate, service, parcel}, _from, state) do
    result =
      case Map.get(@carriers, service) do
        nil ->
          {:error, "Unknown service: #{service}"}

        carrier ->
          if parcel.weight_kg > carrier.max_weight_kg do
            {:error, "Parcel exceeds maximum weight for #{service}"}
          else
            cost = compute_cost(carrier, parcel)
            {:ok, %{service: service, cost: cost, currency: "USD"}}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cheapest_option, parcel}, _from, state) do
    eligible =
      @carriers
      |> Enum.filter(fn {_name, c} -> parcel.weight_kg <= c.max_weight_kg end)
      |> Enum.map(fn {name, c} -> {name, compute_cost(c, parcel)} end)
      |> Enum.min_by(fn {_name, cost} -> cost end, fn -> nil end)

    result =
      case eligible do
        nil -> {:error, "No services available for this parcel"}
        {name, cost} -> {:ok, %{service: name, cost: cost, currency: "USD"}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:transit_days, service, _distance_km}, _from, state) do
    result =
      case Map.get(@carriers, service) do
        nil -> {:error, "Unknown service: #{service}"}
        %{transit_days: days} -> {:ok, days}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:available_services, parcel}, _from, state) do
    services =
      @carriers
      |> Enum.filter(fn {_name, c} -> parcel.weight_kg <= c.max_weight_kg end)
      |> Enum.map(fn {name, c} ->
        %{service: name, cost: compute_cost(c, parcel), transit_days: c.transit_days}
      end)
      |> Enum.sort_by(& &1.cost)

    {:reply, {:ok, services}, state}
  end

  # VALIDATION: SMELL END

  defp compute_cost(%{base_rate: base, per_kg: pkg, per_km: pkm}, parcel) do
    raw = base + parcel.weight_kg * pkg + parcel.distance_km * pkm
    Float.round(raw, 2)
  end
end
```
