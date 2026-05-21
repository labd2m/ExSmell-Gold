```elixir
defmodule Billing.InvoiceCalculator do
  use GenServer

  @moduledoc """
  Computes financial totals for draft and finalized invoices.
  Used by the invoicing service before persisting invoice records to the database.
  """



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

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.reduce(0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)
    |> Float.round(2)
  end
end
```
