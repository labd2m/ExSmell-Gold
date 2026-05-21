```elixir
defmodule Commerce.TaxCalculator do
  use GenServer

  @moduledoc """
  Computes sales tax for orders placed in different regions and product
  categories. Used by the checkout pipeline to determine final order totals.
  """

  @tax_rates %{
    # {region, category} => rate
    {:us_ca, :electronics}   => 0.0975,
    {:us_ca, :clothing}      => 0.0725,
    {:us_ca, :groceries}     => 0.00,
    {:us_ca, :general}       => 0.0725,
    {:us_ny, :electronics}   => 0.08875,
    {:us_ny, :clothing}      => 0.04875,
    {:us_ny, :groceries}     => 0.00,
    {:us_ny, :general}       => 0.08875,
    {:us_tx, :electronics}   => 0.0825,
    {:us_tx, :clothing}      => 0.0825,
    {:us_tx, :groceries}     => 0.00,
    {:us_tx, :general}       => 0.0825,
    {:eu_de, :electronics}   => 0.19,
    {:eu_de, :clothing}      => 0.19,
    {:eu_de, :groceries}     => 0.07,
    {:eu_de, :general}       => 0.19,
    {:eu_fr, :electronics}   => 0.20,
    {:eu_fr, :clothing}      => 0.20,
    {:eu_fr, :groceries}     => 0.055,
    {:eu_fr, :general}       => 0.20,
    {:br_sp, :electronics}   => 0.12,
    {:br_sp, :clothing}      => 0.18,
    {:br_sp, :groceries}     => 0.07,
    {:br_sp, :general}       => 0.17
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc "Returns `{:ok, tax_amount}` for the given region, category, and subtotal."
  def compute_tax(pid, %{region: region, category: category, subtotal: subtotal}) do
    GenServer.call(pid, {:compute_tax, region, category, subtotal})
  end

  @doc "Returns the subtotal minus any applicable tax exemption (net pre-tax amount)."
  def net_amount(pid, %{region: region, category: category, gross: gross}) do
    GenServer.call(pid, {:net_amount, region, category, gross})
  end

  @doc "Returns the gross amount (subtotal + tax) for display on invoices."
  def gross_amount(pid, %{region: region, category: category, net: net}) do
    GenServer.call(pid, {:gross_amount, region, category, net})
  end

  @doc "Returns the tax rate for a given region and category."
  def applicable_rate(pid, region, category) do
    GenServer.call(pid, {:applicable_rate, region, category})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:compute_tax, region, category, subtotal}, _from, state) do
    result =
      case Map.get(@tax_rates, {region, category}) do
        nil  -> {:error, :unknown_region_category}
        rate -> {:ok, Float.round(subtotal * rate, 2)}
      end

    {:reply, result, state}
  end

  def handle_call({:net_amount, region, category, gross}, _from, state) do
    result =
      case Map.get(@tax_rates, {region, category}) do
        nil  -> {:error, :unknown_region_category}
        rate -> {:ok, Float.round(gross / (1 + rate), 2)}
      end

    {:reply, result, state}
  end

  def handle_call({:gross_amount, region, category, net}, _from, state) do
    result =
      case Map.get(@tax_rates, {region, category}) do
        nil  -> {:error, :unknown_region_category}
        rate -> {:ok, Float.round(net * (1 + rate), 2)}
      end

    {:reply, result, state}
  end

  def handle_call({:applicable_rate, region, category}, _from, state) do
    result =
      case Map.get(@tax_rates, {region, category}) do
        nil  -> {:error, :unknown_region_category}
        rate -> {:ok, rate}
      end

    {:reply, result, state}
  end

end
```
