# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Billing.InvoiceCalculator` module
- **Affected function(s)**: `subtotal/2`, `total/2`, `line_totals/2`, `summary/2`
- **Short explanation**: Invoice arithmetic—summing line items, applying taxes, and computing totals—is deterministic and free of side effects. The `GenServer` stores no meaningful state (just an empty map). All invoice compilation operations must serialize through this single process even though they can trivially be executed in parallel as pure functions.

## Code

```elixir
defmodule Billing.InvoiceCalculator do
  use GenServer

  @moduledoc """
  Computes financial totals for draft and finalized invoices.
  Used by the invoicing service before persisting invoice records to the database.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because InvoiceCalculator is a GenServer whose
  # VALIDATION: entire purpose is arithmetic on invoice data structures passed in
  # VALIDATION: per call. The process state is an empty map that is never used.
  # VALIDATION: There is no shared resource, no mutable state, and no concurrency
  # VALIDATION: concern. Billing workloads frequently compute dozens of invoices in
  # VALIDATION: parallel; funneling all of them through one process is a bottleneck
  # VALIDATION: caused entirely by organizing code as a process instead of a module.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Computes the subtotal (sum of all line items before tax and discounts).
  `line_items` is a list of `%{quantity: n, unit_price: float}` maps.
  """
  def subtotal(pid, line_items) do
    GenServer.call(pid, {:subtotal, line_items})
  end

  @doc """
  Computes the grand total after applying `tax_rate` and an optional discount.
  """
  def total(pid, invoice) do
    GenServer.call(pid, {:total, invoice})
  end

  @doc """
  Returns each line item enriched with `:line_total`.
  """
  def line_totals(pid, line_items) do
    GenServer.call(pid, {:line_totals, line_items})
  end

  @doc """
  Returns a full financial summary map for an invoice.
  """
  def summary(pid, invoice) do
    GenServer.call(pid, {:summary, invoice})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:subtotal, line_items}, _from, state) do
    total =
      line_items
      |> Enum.reduce(0.0, fn item, acc ->
        acc + item.quantity * item.unit_price
      end)
      |> Float.round(2)

    {:reply, {:ok, total}, state}
  end

  @impl true
  def handle_call({:total, invoice}, _from, state) do
    sub = compute_subtotal(invoice.line_items)
    discount = Map.get(invoice, :discount, 0.0)
    tax_rate = Map.get(invoice, :tax_rate, 0.0)
    after_discount = sub - discount
    tax_amount = Float.round(after_discount * tax_rate, 2)
    grand_total = Float.round(after_discount + tax_amount, 2)
    {:reply, {:ok, grand_total}, state}
  end

  @impl true
  def handle_call({:line_totals, line_items}, _from, state) do
    enriched =
      Enum.map(line_items, fn item ->
        Map.put(item, :line_total, Float.round(item.quantity * item.unit_price, 2))
      end)

    {:reply, {:ok, enriched}, state}
  end

  @impl true
  def handle_call({:summary, invoice}, _from, state) do
    sub = compute_subtotal(invoice.line_items)
    discount = Map.get(invoice, :discount, 0.0)
    tax_rate = Map.get(invoice, :tax_rate, 0.0)
    after_discount = sub - discount
    tax_amount = Float.round(after_discount * tax_rate, 2)
    grand_total = Float.round(after_discount + tax_amount, 2)

    summary = %{
      line_count: length(invoice.line_items),
      subtotal: sub,
      discount: discount,
      taxable_amount: after_discount,
      tax_rate: tax_rate,
      tax_amount: tax_amount,
      grand_total: grand_total,
      currency: Map.get(invoice, :currency, "USD")
    }

    {:reply, {:ok, summary}, state}
  end

  # VALIDATION: SMELL END

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.reduce(0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)
    |> Float.round(2)
  end
end
```
