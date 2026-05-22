# Annotated Example — Code Smell: Comments

- **Smell name:** Comments
- **Expected smell location:** `MyApp.Reporting.SalesReport` module, function `build/2`
- **Affected function(s):** `build/2`, `export_csv/2`
- **Short explanation:** Both public functions carry long descriptive `#` comments that explain their purpose, parameters, options, and return values — information that belongs in `@doc` strings. The developer essentially wrote `@doc`-quality documentation but placed it in syntactically invisible comment form, making it unreachable through Elixir's documentation toolchain.

```elixir
defmodule MyApp.Reporting.SalesReport do
  @moduledoc false

  alias MyApp.Repo
  alias MyApp.Sales.{Order, Product, Region}
  alias NimbleCSV.RFC4180, as: CSV

  @max_export_rows 50_000

  ###############################################################
  # Builds an in-memory sales report for the specified date range.
  #
  # Parameters:
  #   date_range  - a Date.Range struct (e.g. Date.range(~D[2024-01-01], ~D[2024-03-31]))
  #   opts        - keyword list of optional filters:
  #                   :region_ids   - list of region IDs to include (default: all)
  #                   :product_ids  - list of product IDs to include (default: all)
  #                   :group_by     - :product | :region | :day (default: :product)
  #                   :currency     - ISO 4217 code string (default: "USD")
  #
  # Returns:
  #   {:ok, %{rows: [map()], summary: map()}} on success, where each row
  #   contains :label, :units_sold, :gross_revenue, :returns, :net_revenue.
  #   {:error, :empty_range} if the date range has no days.
  #   {:error, :query_failed} if the database query errors.
  ###############################################################
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `build/2` is documented using
  # VALIDATION: `#` comment blocks instead of `@doc`. Documentation written
  # VALIDATION: this way cannot be queried with `h MyApp.Reporting.SalesReport.build/2`
  # VALIDATION: in IEx and won't appear in any generated documentation.
  def build(%Date.Range{} = date_range, opts \\ []) do
    # VALIDATION: SMELL END
    if Enum.count(date_range) == 0 do
      {:error, :empty_range}
    else
      region_ids = Keyword.get(opts, :region_ids, :all)
      product_ids = Keyword.get(opts, :product_ids, :all)
      group_by = Keyword.get(opts, :group_by, :product)
      currency = Keyword.get(opts, :currency, "USD")

      query_result =
        try do
          Repo.all(
            build_query(date_range, region_ids, product_ids, group_by, currency)
          )
        rescue
          _ -> :error
        end

      case query_result do
        :error ->
          {:error, :query_failed}

        rows ->
          summary = summarize(rows)
          {:ok, %{rows: rows, summary: summary}}
      end
    end
  end

  ###############################################################
  # Exports a previously built report to CSV format.
  #
  # Parameters:
  #   report   - the map returned by build/2 (the :ok tuple's second element)
  #   filepath - absolute path string where the CSV file should be written
  #
  # Behaviour:
  #   Writes a header row followed by one row per report entry.
  #   Rows exceeding @max_export_rows are truncated with a warning logged.
  #
  # Returns:
  #   {:ok, filepath} on success.
  #   {:error, :too_many_rows} if row count exceeds the configured maximum.
  #   {:error, :write_failed} if the file cannot be written.
  ###############################################################
  def export_csv(%{rows: rows}, filepath) when is_binary(filepath) do
    if length(rows) > @max_export_rows do
      {:error, :too_many_rows}
    else
      headers = [["Label", "Units Sold", "Gross Revenue", "Returns", "Net Revenue"]]

      data =
        Enum.map(rows, fn row ->
          [row.label, row.units_sold, row.gross_revenue, row.returns, row.net_revenue]
        end)

      csv_content =
        (headers ++ data)
        |> CSV.dump_to_iodata()
        |> IO.iodata_to_binary()

      case File.write(filepath, csv_content) do
        :ok -> {:ok, filepath}
        {:error, _} -> {:error, :write_failed}
      end
    end
  end

  defp build_query(date_range, region_ids, product_ids, group_by, currency) do
    import Ecto.Query

    base =
      from o in Order,
        where: o.ordered_at >= ^date_range.first and o.ordered_at <= ^date_range.last,
        where: o.currency == ^currency

    base
    |> maybe_filter_regions(region_ids)
    |> maybe_filter_products(product_ids)
    |> apply_grouping(group_by)
  end

  defp maybe_filter_regions(query, :all), do: query

  defp maybe_filter_regions(query, ids) do
    import Ecto.Query
    where(query, [o], o.region_id in ^ids)
  end

  defp maybe_filter_products(query, :all), do: query

  defp maybe_filter_products(query, ids) do
    import Ecto.Query
    where(query, [o], o.product_id in ^ids)
  end

  defp apply_grouping(query, _group_by), do: query

  defp summarize(rows) do
    %{
      total_units: Enum.sum(Enum.map(rows, & &1.units_sold)),
      total_gross: Enum.sum(Enum.map(rows, & &1.gross_revenue)),
      total_net: Enum.sum(Enum.map(rows, & &1.net_revenue))
    }
  end
end
```
