# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `ReportAggregator` module — entire GenServer structure |
| **Affected function(s)** | `summarize_sales/2`, `top_products/3`, `revenue_by_region/2`, `monthly_breakdown/2` |
| **Short explanation** | All operations aggregate and transform lists of sales records passed in by the caller. No state is accumulated in the server between calls, and no external resource is accessed. The computations are pure data transformations that could run in parallel across multiple caller processes instead of being serialised. |

```elixir
defmodule Reporting.ReportAggregator do
  use GenServer

  @moduledoc """
  Aggregates raw sales event records into summary statistics used
  by the management dashboard and scheduled report emails.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because every function aggregates an
  # in-memory list of records passed by the caller. The GenServer
  # maintains no state between requests. Report generation is CPU-bound
  # and embarrassingly parallelisable, yet routing all requests through
  # a single process turns it into a serial bottleneck under load.

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns a top-level summary map for the given list of `sales` records.
  Each record: `%{amount: float, region: atom, product_id: binary, date: Date}`.
  """
  def summarize_sales(pid, sales) do
    GenServer.call(pid, {:summarize_sales, sales})
  end

  @doc "Returns the top `n` products by total revenue, sorted descending."
  def top_products(pid, sales, n \\ 10) do
    GenServer.call(pid, {:top_products, sales, n})
  end

  @doc "Returns a map of `%{region => total_revenue}` for the sales list."
  def revenue_by_region(pid, sales) do
    GenServer.call(pid, {:revenue_by_region, sales})
  end

  @doc "Returns a list of `%{month: string, revenue: float, count: int}` maps."
  def monthly_breakdown(pid, sales) do
    GenServer.call(pid, {:monthly_breakdown, sales})
  end

  @doc "Returns the average order value for the sales list."
  def average_order_value(pid, sales) do
    GenServer.call(pid, {:average_order_value, sales})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:summarize_sales, sales}, _from, state) do
    total_revenue = Enum.reduce(sales, 0.0, fn s, acc -> acc + s.amount end)
    order_count   = length(sales)
    avg           = if order_count > 0, do: Float.round(total_revenue / order_count, 2), else: 0.0
    regions       = sales |> Enum.map(& &1.region) |> Enum.uniq() |> length()

    summary = %{
      total_revenue: Float.round(total_revenue, 2),
      order_count:   order_count,
      average_order: avg,
      unique_regions: regions
    }

    {:reply, {:ok, summary}, state}
  end

  def handle_call({:top_products, sales, n}, _from, state) do
    top =
      sales
      |> Enum.group_by(& &1.product_id)
      |> Enum.map(fn {pid, records} ->
        %{
          product_id: pid,
          revenue:    Float.round(Enum.reduce(records, 0.0, fn r, acc -> acc + r.amount end), 2),
          orders:     length(records)
        }
      end)
      |> Enum.sort_by(& &1.revenue, :desc)
      |> Enum.take(n)

    {:reply, {:ok, top}, state}
  end

  def handle_call({:revenue_by_region, sales}, _from, state) do
    by_region =
      Enum.reduce(sales, %{}, fn sale, acc ->
        Map.update(acc, sale.region, sale.amount, fn prev -> prev + sale.amount end)
      end)
      |> Enum.into(%{}, fn {region, total} -> {region, Float.round(total, 2)} end)

    {:reply, {:ok, by_region}, state}
  end

  def handle_call({:monthly_breakdown, sales}, _from, state) do
    breakdown =
      sales
      |> Enum.group_by(fn s -> Calendar.strftime(s.date, "%Y-%m") end)
      |> Enum.map(fn {month, records} ->
        %{
          month:   month,
          revenue: Float.round(Enum.reduce(records, 0.0, fn r, acc -> acc + r.amount end), 2),
          count:   length(records)
        }
      end)
      |> Enum.sort_by(& &1.month)

    {:reply, {:ok, breakdown}, state}
  end

  def handle_call({:average_order_value, sales}, _from, state) do
    result =
      case length(sales) do
        0 -> {:ok, 0.0}
        n ->
          total = Enum.reduce(sales, 0.0, fn s, acc -> acc + s.amount end)
          {:ok, Float.round(total / n, 2)}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END
end
```
