# Annotated Example 10

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Reports.SalesAggregator.aggregate/2`, lines where `filters` map keys are accessed dynamically
- **Affected function(s):** `aggregate/2`
- **Short explanation:** `filters[:date_from]`, `filters[:date_to]`, `filters[:region]`, and `filters[:product_category]` use dynamic bracket access on an unvalidated plain map. Absent keys silently return `nil`, which is then fed into `Date.compare/2` and string-matching logic, masking missing filter configuration and producing incorrect report output.

---

```elixir
defmodule Reports.SalesAggregator do
  @moduledoc """
  Aggregates raw sales transaction records into summary reports filtered
  by date range, region, and product category.
  """

  require Logger

  @type transaction :: %{
          id: String.t(),
          amount: float(),
          date: Date.t(),
          region: String.t(),
          product_category: String.t(),
          salesperson_id: String.t()
        }

  @type report :: %{
          total_revenue: float(),
          transaction_count: integer(),
          avg_transaction: float(),
          by_region: map(),
          by_category: map()
        }

  @spec aggregate(list(transaction()), map()) :: {:ok, report()} | {:error, String.t()}
  def aggregate(transactions, filters) when is_list(transactions) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `filters[:date_from]`,
    # `filters[:date_to]`, `filters[:region]`, and `filters[:product_category]`
    # use dynamic bracket access. If `:date_from` is absent, `nil` is passed to
    # `Date.compare(tx.date, nil)`, raising a `FunctionClauseError` at runtime.
    # For `:region` and `:product_category`, a missing key is
    # indistinguishable from an explicit `nil` (meaning "no filter"), silently
    # changing report semantics without any warning.
    date_from        = filters[:date_from]
    date_to          = filters[:date_to]
    region           = filters[:region]
    product_category = filters[:product_category]
    # VALIDATION: SMELL END

    filtered =
      transactions
      |> filter_by_date(date_from, date_to)
      |> filter_by_region(region)
      |> filter_by_category(product_category)

    if Enum.empty?(filtered) do
      Logger.warning("No transactions matched the supplied filters")
    end

    report = build_report(filtered)

    {:ok, report}
  rescue
    e ->
      {:error, "Aggregation failed: #{Exception.message(e)}"}
  end

  @spec build_report(list(transaction())) :: report()
  defp build_report(transactions) do
    total = transactions |> Enum.map(& &1.amount) |> Enum.sum()
    count = length(transactions)

    by_region =
      transactions
      |> Enum.group_by(& &1.region)
      |> Map.new(fn {region, txs} ->
        {region, txs |> Enum.map(& &1.amount) |> Enum.sum()}
      end)

    by_category =
      transactions
      |> Enum.group_by(& &1.product_category)
      |> Map.new(fn {cat, txs} ->
        {cat, txs |> Enum.map(& &1.amount) |> Enum.sum()}
      end)

    %{
      total_revenue: Float.round(total, 2),
      transaction_count: count,
      avg_transaction: if(count > 0, do: Float.round(total / count, 2), else: 0.0),
      by_region: by_region,
      by_category: by_category
    }
  end

  @spec filter_by_date(list(transaction()), Date.t() | nil, Date.t() | nil) ::
          list(transaction())
  defp filter_by_date(txs, nil, nil), do: txs

  defp filter_by_date(txs, date_from, nil) do
    Enum.filter(txs, fn tx -> Date.compare(tx.date, date_from) in [:gt, :eq] end)
  end

  defp filter_by_date(txs, nil, date_to) do
    Enum.filter(txs, fn tx -> Date.compare(tx.date, date_to) in [:lt, :eq] end)
  end

  defp filter_by_date(txs, date_from, date_to) do
    Enum.filter(txs, fn tx ->
      Date.compare(tx.date, date_from) in [:gt, :eq] and
        Date.compare(tx.date, date_to) in [:lt, :eq]
    end)
  end

  @spec filter_by_region(list(transaction()), String.t() | nil) :: list(transaction())
  defp filter_by_region(txs, nil), do: txs

  defp filter_by_region(txs, region) do
    Enum.filter(txs, fn tx -> tx.region == region end)
  end

  @spec filter_by_category(list(transaction()), String.t() | nil) :: list(transaction())
  defp filter_by_category(txs, nil), do: txs

  defp filter_by_category(txs, category) do
    Enum.filter(txs, fn tx -> tx.product_category == category end)
  end
end
```
