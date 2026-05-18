```elixir
defmodule Reporting.Pagination do
  @moduledoc """
  Provides in-memory pagination helpers for reports and list APIs.
  Intended for moderate-sized result sets fetched entirely before rendering.
  """

  @default_page_size 25

  defmacro paginate(items, opts) do
    quote do
      options = unquote(opts)
      page = Keyword.get(options, :page, 1)
      size = Keyword.get(options, :page_size, unquote(@default_page_size))
      offset = (page - 1) * size

      unquote(items)
      |> Enum.drop(offset)
      |> Enum.take(size)
    end
  end

  @doc """
  Computes pagination metadata given a total item count and pagination options.
  """
  @spec metadata(non_neg_integer(), keyword()) :: map()
  def metadata(total_count, opts) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    total_pages = ceil(total_count / page_size)

    %{
      page: page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_previous: page > 1
    }
  end
end

defmodule Reporting.SalesReport do
  @moduledoc """
  Generates paginated sales reports grouped by product, region, or time period.
  Used by the finance dashboard and scheduled CSV exports.
  """

  require Reporting.Pagination

  alias Reporting.Pagination

  @doc """
  Builds a paginated sales report for the given date range.
  Returns a map containing the page of results and pagination metadata.
  """
  @spec generate(list(map()), Date.t(), Date.t(), keyword()) :: map()
  def generate(transactions, from_date, to_date, opts \\ []) do
    filtered =
      transactions
      |> Enum.filter(fn tx ->
        date = DateTime.to_date(tx.completed_at)
        Date.compare(date, from_date) != :lt and Date.compare(date, to_date) != :gt
      end)
      |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})

    page_items = Pagination.paginate(filtered, opts)
    meta = Pagination.metadata(length(filtered), opts)

    %{
      results: page_items,
      pagination: meta,
      period: %{from: from_date, to: to_date},
      generated_at: DateTime.utc_now()
    }
  end

  @doc """
  Summarises the totals for a list of transactions.
  """
  @spec summarise(list(map())) :: map()
  def summarise(transactions) do
    total_revenue = Enum.reduce(transactions, 0, &(&1.amount_cents + &2))
    total_refunds = Enum.reduce(transactions, 0, &(&1.refunded_cents + &2))
    net_revenue = total_revenue - total_refunds

    %{
      transaction_count: length(transactions),
      total_revenue_cents: total_revenue,
      total_refunds_cents: total_refunds,
      net_revenue_cents: net_revenue
    }
  end

  @doc """
  Groups a list of transactions by the sales region field.
  """
  @spec by_region(list(map())) :: map()
  def by_region(transactions) do
    transactions
    |> Enum.group_by(& &1.region)
    |> Map.new(fn {region, txs} -> {region, summarise(txs)} end)
  end

  @doc """
  Produces a CSV-formatted string for a list of transaction maps.
  """
  @spec to_csv(list(map())) :: String.t()
  def to_csv(transactions) do
    header = "id,region,amount_cents,refunded_cents,completed_at\n"

    rows =
      Enum.map_join(transactions, "\n", fn tx ->
        "#{tx.id},#{tx.region},#{tx.amount_cents},#{tx.refunded_cents},#{DateTime.to_iso8601(tx.completed_at)}"
      end)

    header <> rows
  end
end
```
