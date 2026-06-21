# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Billing.TaxCalculator` module
- **Affected function(s)**: `calculate/3`, `effective_rate/2`, `breakdown/3`, `gross_up/3`
- **Short explanation**: All tax calculations are purely mathematical, operating only on input arguments and a fixed configuration map. No mutable state, no I/O, and no resource contention exist. Using a `GenServer` to host these computations forces every billing operation to serialize through one process, reducing throughput with no architectural benefit.

## Code

```elixir
defmodule Billing.TaxCalculator do
  use GenServer

  @moduledoc """
  Computes tax obligations for invoices, line items, and gross-up scenarios
  across multiple jurisdictions. Used by the billing pipeline before emitting
  payment requests.
  """

  @tax_rules %{
    "BR-SP" => %{rate: 0.12, name: "ICMS", compound: false},
    "BR-RJ" => %{rate: 0.14, name: "ICMS", compound: false},
    "US-CA" => %{rate: 0.0725, name: "Sales Tax", compound: false},
    "US-NY" => %{rate: 0.08875, name: "Sales Tax", compound: false},
    "DE"    => %{rate: 0.19, name: "VAT", compound: false},
    "FR"    => %{rate: 0.20, name: "TVA", compound: false},
    "GB"    => %{rate: 0.20, name: "VAT", compound: false},
    "AU"    => %{rate: 0.10, name: "GST", compound: false}
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because TaxCalculator is a GenServer whose state is
  # VALIDATION: never written to after initialization. Every handle_call reads from
  # VALIDATION: a module-level constant (@tax_rules) and performs arithmetic. There
  # VALIDATION: is no shared resource, no event scheduling, and no concurrency
  # VALIDATION: concern. Routing all tax computation through one process is purely
  # VALIDATION: an organizational choice that introduces unnecessary serialization.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Calculates the tax amount for `net_amount` in the given `jurisdiction`.
  `category` can be `:goods` or `:services`.
  """
  def calculate(pid, net_amount, jurisdiction) do
    GenServer.call(pid, {:calculate, net_amount, jurisdiction})
  end

  @doc """
  Returns the effective tax rate (as a float) for a jurisdiction.
  """
  def effective_rate(pid, jurisdiction) do
    GenServer.call(pid, {:effective_rate, jurisdiction})
  end

  @doc """
  Returns a detailed breakdown map for a net amount in a jurisdiction.
  """
  def breakdown(pid, net_amount, jurisdiction) do
    GenServer.call(pid, {:breakdown, net_amount, jurisdiction})
  end

  @doc """
  Given a target gross amount, returns the net amount that, when taxed,
  yields exactly the gross.
  """
  def gross_up(pid, gross_amount, jurisdiction) do
    GenServer.call(pid, {:gross_up, gross_amount, jurisdiction})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:calculate, net_amount, jurisdiction}, _from, state) do
    result =
      case Map.get(@tax_rules, jurisdiction) do
        nil -> {:error, "Unknown jurisdiction: #{jurisdiction}"}
        %{rate: rate} -> {:ok, Float.round(net_amount * rate, 2)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:effective_rate, jurisdiction}, _from, state) do
    result =
      case Map.get(@tax_rules, jurisdiction) do
        nil -> {:error, "Unknown jurisdiction: #{jurisdiction}"}
        %{rate: rate} -> {:ok, rate}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:breakdown, net_amount, jurisdiction}, _from, state) do
    result =
      case Map.get(@tax_rules, jurisdiction) do
        nil ->
          {:error, "Unknown jurisdiction: #{jurisdiction}"}

        %{rate: rate, name: name} ->
          tax = Float.round(net_amount * rate, 2)
          gross = Float.round(net_amount + tax, 2)

          {:ok,
           %{
             jurisdiction: jurisdiction,
             tax_name: name,
             net: net_amount,
             tax_rate: rate,
             tax_amount: tax,
             gross: gross
           }}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:gross_up, gross_amount, jurisdiction}, _from, state) do
    result =
      case Map.get(@tax_rules, jurisdiction) do
        nil -> {:error, "Unknown jurisdiction: #{jurisdiction}"}
        %{rate: rate} ->
          net = Float.round(gross_amount / (1 + rate), 2)
          {:ok, net}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END

  @doc false
  def list_jurisdictions, do: Map.keys(@tax_rules)
end
```
