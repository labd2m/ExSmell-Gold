```elixir
defmodule Reporting.SalesAggregator do
  use GenServer

  @moduledoc """
  Aggregates raw sales transaction data into summary reports.
  Consumed by the reporting dashboard and scheduled export jobs.
  """



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Aggregates transactions by time period (`:day`, `:week`, `:month`).
  Returns a list of `%{period: date, revenue: float, count: integer}` maps.
  """
  def by_period(pid, transactions, period \\ :month) do
    GenServer.call(pid, {:by_period, transactions, period})
  end

  @doc """
  Aggregates transactions by product SKU.
  """
  def by_product(pid, transactions) do
    GenServer.call(pid, {:by_product, transactions})
  end

  @doc """
  Aggregates transactions by region code.
  """
  def by_region(pid, transactions) do
    GenServer.call(pid, {:by_region, transactions})
  end

  @doc """
  Returns the top N products or regions by total revenue.
  """
  def top_n(pid, transactions, n) do
    GenServer.call(pid, {:top_n, transactions, n})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:by_period, transactions, period}, _from, state) do
    grouped =
      transactions
      |> Enum.group_by(fn tx -> truncate_date(tx.inserted_at, period) end)
      |> Enum.map(fn {period_date, txs} ->
        %{
          period: period_date,
          revenue: txs |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(2),
          count: length(txs),
          avg_order: (Enum.sum(Enum.map(txs, & &1.amount)) / length(txs)) |> Float.round(2)
        }
      end)
      |> Enum.sort_by(& &1.period, Date)

    {:reply, {:ok, grouped}, state}
  end

  @impl true
  def handle_call({:by_product, transactions}, _from, state) do
    result =
      transactions
      |> Enum.group_by(& &1.product_sku)
      |> Enum.map(fn {sku, txs} ->
        %{
          sku: sku,
          units_sold: Enum.sum(Enum.map(txs, & &1.quantity)),
          revenue: txs |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(2),
          transaction_count: length(txs)
        }
      end)
      |> Enum.sort_by(& &1.revenue, :desc)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:by_region, transactions}, _from, state) do
    result =
      transactions
      |> Enum.group_by(& &1.region)
      |> Enum.map(fn {region, txs} ->
        %{
          region: region,
          revenue: txs |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(2),
          transaction_count: length(txs),
          unique_customers: txs |> Enum.map(& &1.customer_id) |> Enum.uniq() |> length()
        }
      end)
      |> Enum.sort_by(& &1.revenue, :desc)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:top_n, transactions, n}, _from, state) do
    top =
      transactions
      |> Enum.group_by(& &1.product_sku)
      |> Enum.map(fn {sku, txs} ->
        {sku, txs |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(2)}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(n)
      |> Enum.map(fn {sku, revenue} -> %{sku: sku, revenue: revenue} end)

    {:reply, {:ok, top}, state}
  end

  defp truncate_date(datetime, :day), do: DateTime.to_date(datetime)

  defp truncate_date(datetime, :week) do
    date = DateTime.to_date(datetime)
    day_of_week = Date.day_of_week(date)
    Date.add(date, -(day_of_week - 1))
  end

  defp truncate_date(datetime, :month) do
    date = DateTime.to_date(datetime)
    Date.new!(date.year, date.month, 1)
  end
end
```
