# Annotated Example 01

- **Smell name:** Code organization by process
- **Expected smell location:** `TaxCalculator` module — `GenServer` implementation
- **Affected functions:** `compute_sales_tax/2`, `compute_vat/2`, `compute_withholding/2`, `apply_tax_bracket/2`, `effective_rate/2`
- **Short explanation:** All operations in this module are pure, stateless arithmetic computations on tax values. No shared mutable state, no concurrency requirement, and no I/O is involved. Wrapping them inside a `GenServer` forces every call to be serialized through a single process, creating an unnecessary bottleneck and adding process-management overhead for what should simply be module-level functions.

```elixir
defmodule Billing.TaxCalculator do
  use GenServer

  @moduledoc """
  Provides tax computation utilities for the billing pipeline.
  Handles sales tax, VAT, withholding tax, and bracket-based
  effective rate calculations used during invoice generation.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the TaxCalculator server. Should be started under the billing
  supervision tree before invoices are processed.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because all functions below are pure computations
  # with no state and no concurrency need. Routing them through a GenServer
  # serializes calls unnecessarily and can bottleneck high-volume billing pipelines.

  @doc "Computes sales tax amount for a given subtotal and rate (0.0–1.0)."
  def compute_sales_tax(pid, %{subtotal: subtotal, rate: rate}) do
    GenServer.call(pid, {:compute_sales_tax, subtotal, rate})
  end

  @doc "Computes VAT amount for a given net amount and VAT rate."
  def compute_vat(pid, %{net_amount: net, rate: rate}) do
    GenServer.call(pid, {:compute_vat, net, rate})
  end

  @doc """
  Computes withholding tax to be deducted from a gross payment.
  Returns a map with :gross, :withheld, and :net keys.
  """
  def compute_withholding(pid, %{gross: gross, rate: rate}) do
    GenServer.call(pid, {:compute_withholding, gross, rate})
  end

  @doc """
  Applies a stepped tax bracket table to a taxable income amount.
  `brackets` is a list of `{limit, rate}` tuples sorted ascending by limit.
  The last bracket should use `:infinity` as the limit.
  """
  def apply_tax_bracket(pid, %{income: income, brackets: brackets}) do
    GenServer.call(pid, {:apply_tax_bracket, income, brackets})
  end

  @doc """
  Returns the effective tax rate as a float given total tax paid and gross income.
  """
  def effective_rate(pid, %{tax_paid: tax_paid, gross_income: gross_income}) do
    GenServer.call(pid, {:effective_rate, tax_paid, gross_income})
  end

  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:compute_sales_tax, subtotal, rate}, _from, state) do
    tax = Float.round(subtotal * rate, 2)
    {:reply, {:ok, tax}, state}
  end

  @impl true
  def handle_call({:compute_vat, net, rate}, _from, state) do
    vat = Float.round(net * rate, 2)
    {:reply, {:ok, vat}, state}
  end

  @impl true
  def handle_call({:compute_withholding, gross, rate}, _from, state) do
    withheld = Float.round(gross * rate, 2)
    net = Float.round(gross - withheld, 2)
    {:reply, {:ok, %{gross: gross, withheld: withheld, net: net}}, state}
  end

  @impl true
  def handle_call({:apply_tax_bracket, income, brackets}, _from, state) do
    tax = calculate_bracket_tax(income, brackets, 0, 0.0)
    {:reply, {:ok, Float.round(tax, 2)}, state}
  end

  @impl true
  def handle_call({:effective_rate, _tax_paid, 0.0}, _from, state) do
    {:reply, {:error, :division_by_zero}, state}
  end

  @impl true
  def handle_call({:effective_rate, tax_paid, gross_income}, _from, state) do
    rate = Float.round(tax_paid / gross_income, 6)
    {:reply, {:ok, rate}, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp calculate_bracket_tax(_income, [], _prev_limit, acc), do: acc

  defp calculate_bracket_tax(income, [{limit, rate} | rest], prev_limit, acc) do
    cap = if limit == :infinity, do: income, else: min(income, limit)
    taxable_slice = max(cap - prev_limit, 0)
    new_acc = acc + taxable_slice * rate

    if income <= limit or limit == :infinity do
      new_acc
    else
      calculate_bracket_tax(income, rest, limit, new_acc)
    end
  end
end
```
