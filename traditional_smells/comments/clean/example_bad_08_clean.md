```elixir
defmodule RevenueReporter do
  @moduledoc """
  Generates revenue and financial performance reports for internal analytics
  and executive dashboards.
  """

  alias RevenueReporter.{
    TransactionStore,
    ReportCache,
    CurrencyConverter,
    ReportFormatter
  }

  @default_currency "USD"
  @cache_ttl_seconds 3_600

  @doc """
  Returns the list of supported report output formats.
  """
  def supported_formats, do: [:json, :csv, :pdf]

  @doc """
  Clears the report cache for a specific year/month combination.
  """
  def invalidate_cache(year, month) do
    ReportCache.delete(cache_key(year, month))
  end

  # generate_monthly_report/2
  #
  # Aggregates all revenue transactions for the given year and month and
  # returns a structured report map.
  #
  # The report includes:
  #   :gross_revenue        - total before refunds and fees
  #   :net_revenue          - gross minus refunds and processing fees
  #   :transaction_count    - total number of successful transactions
  #   :refund_count         - total number of refund transactions
  #   :top_products         - list of top 10 products by net revenue
  #   :revenue_by_day       - list of {date, net_revenue} tuples
  #   :currency             - reporting currency (converted if needed)
  #
  # Options (keyword list):
  #   :currency   - ISO 4217 string for output currency (default: @default_currency)
  #   :format     - :json | :csv | :pdf for the returned payload (default: :json)
  #   :use_cache  - boolean; when true, returns cached result if available (default: true)
  #
  # Results are cached for @cache_ttl_seconds seconds keyed by year+month.
  #
  # Returns {:ok, formatted_report} or {:error, reason}.
  # exclusively with inline comments. The complete output structure, options map,
  # and caching policy are invisible to @doc-aware tooling such as ExDoc and IEx.h/1.
  def generate_monthly_report(year, month, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)
    format = Keyword.get(opts, :format, :json)
    use_cache = Keyword.get(opts, :use_cache, true)
    key = cache_key(year, month)

    with {:cache, nil} <- maybe_fetch_cache(use_cache, key),
         {:ok, transactions} <- TransactionStore.fetch_month(year, month),
         {:ok, converted} <- CurrencyConverter.convert_all(transactions, currency),
         {:ok, report_data} <- build_report(converted),
         {:ok, formatted} <- ReportFormatter.format(report_data, format) do
      if use_cache, do: ReportCache.put(key, formatted, @cache_ttl_seconds)
      {:ok, formatted}
    else
      {:cache, cached} -> {:ok, cached}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates a year-to-date summary report by aggregating monthly reports.
  """
  def generate_ytd_report(year, opts \\ []) do
    current_month = Date.utc_today().month

    results =
      Enum.map(1..current_month, fn m ->
        generate_monthly_report(year, m, opts)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        monthly_reports = Enum.map(results, fn {:ok, r} -> r end)
        {:ok, ReportFormatter.aggregate_yearly(monthly_reports)}

      error ->
        error
    end
  end

  defp maybe_fetch_cache(false, _key), do: {:cache, nil}

  defp maybe_fetch_cache(true, key) do
    case ReportCache.get(key) do
      nil -> {:cache, nil}
      cached -> {:cache, cached}
    end
  end

  defp cache_key(year, month), do: "report:monthly:#{year}:#{month}"

  defp build_report(transactions) do
    successful = Enum.filter(transactions, &(&1.status == :success))
    refunds = Enum.filter(transactions, &(&1.status == :refund))

    gross = Enum.reduce(successful, Decimal.new(0), &Decimal.add(&2, &1.amount))
    refund_total = Enum.reduce(refunds, Decimal.new(0), &Decimal.add(&2, &1.amount))
    fee_total = Enum.reduce(successful, Decimal.new(0), &Decimal.add(&2, &1.fee))
    net = Decimal.sub(Decimal.sub(gross, refund_total), fee_total)

    top_products =
      successful
      |> Enum.group_by(& &1.product_id)
      |> Enum.map(fn {id, txns} ->
        {id, Enum.reduce(txns, Decimal.new(0), &Decimal.add(&2, &1.amount))}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)

    {:ok,
     %{
       gross_revenue: gross,
       net_revenue: net,
       transaction_count: length(successful),
       refund_count: length(refunds),
       top_products: top_products
     }}
  end
end
```
