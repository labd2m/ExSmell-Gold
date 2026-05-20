```elixir
defmodule ReportGenerator do
  @moduledoc """
  Generates various business reports for the back-office dashboard.
  """

  alias ReportGenerator.{
    FinancialSummaryParams,
    InventoryAuditParams,
    UserActivityParams,
    Repo,
    PDFRenderer,
    CSVExporter
  }

  @doc """
  Generates a report based on the provided parameters struct.

  ## Examples

      iex> ReportGenerator.generate(%FinancialSummaryParams{period: :monthly})
      {:ok, %{format: :pdf, path: "/reports/finance_2024_01.pdf"}}

  """


  def generate(%FinancialSummaryParams{period: period, currency: currency, department_ids: dept_ids}) do
    start_date = period_start(period)
    end_date = Date.utc_today()

    transactions = Repo.fetch_transactions(dept_ids, start_date, end_date)

    summary = %{
      total_revenue: sum_by(transactions, :revenue, currency),
      total_expenses: sum_by(transactions, :expenses, currency),
      net_profit: sum_by(transactions, :revenue, currency) - sum_by(transactions, :expenses, currency),
      period: period,
      departments: dept_ids,
      generated_at: DateTime.utc_now()
    }

    filename = "finance_#{period}_#{Date.to_iso8601(end_date)}.pdf"
    path = Path.join([System.get_env("REPORTS_DIR", "/reports"), filename])

    with {:ok, _} <- PDFRenderer.render(:financial_summary, summary, path) do
      {:ok, %{format: :pdf, path: path}}
    end
  end

  # produces an inventory audit CSV for warehouse reconciliation
  def generate(%InventoryAuditParams{warehouse_ids: warehouse_ids, include_zero_stock: include_zero}) do
    items =
      warehouse_ids
      |> Repo.fetch_inventory_items()
      |> Enum.filter(fn item ->
        include_zero || item.quantity > 0
      end)
      |> Enum.map(fn item ->
        %{
          sku: item.sku,
          description: item.description,
          quantity: item.quantity,
          unit_cost: item.unit_cost,
          total_value: item.quantity * item.unit_cost,
          warehouse: item.warehouse_code,
          last_counted_at: item.last_counted_at
        }
      end)

    filename = "inventory_audit_#{Date.to_iso8601(Date.utc_today())}.csv"
    path = Path.join([System.get_env("REPORTS_DIR", "/reports"), filename])

    with {:ok, _} <- CSVExporter.write(items, path) do
      {:ok, %{format: :csv, path: path, row_count: length(items)}}
    end
  end

  # generates a user activity report for the compliance team
  def generate(%UserActivityParams{from: from, to: to, role_filter: role_filter}) do
    events =
      Repo.fetch_audit_events(from, to)
      |> Enum.filter(fn event ->
        role_filter == :all || event.user_role == role_filter
      end)
      |> Enum.group_by(& &1.user_id)
      |> Enum.map(fn {user_id, user_events} ->
        %{
          user_id: user_id,
          event_count: length(user_events),
          first_activity: Enum.min_by(user_events, & &1.occurred_at).occurred_at,
          last_activity: Enum.max_by(user_events, & &1.occurred_at).occurred_at,
          distinct_actions: user_events |> Enum.map(& &1.action) |> Enum.uniq() |> length()
        }
      end)

    filename = "user_activity_#{Date.to_iso8601(from)}_#{Date.to_iso8601(to)}.csv"
    path = Path.join([System.get_env("REPORTS_DIR", "/reports"), filename])

    with {:ok, _} <- CSVExporter.write(events, path) do
      {:ok, %{format: :csv, path: path, user_count: length(events)}}
    end
  end


  defp period_start(:monthly), do: Date.beginning_of_month(Date.utc_today())
  defp period_start(:quarterly), do: Date.add(Date.utc_today(), -90)
  defp period_start(:yearly), do: %{Date.utc_today() | month: 1, day: 1}

  defp sum_by(transactions, field, _currency) do
    transactions |> Enum.map(&Map.get(&1, field, 0)) |> Enum.sum()
  end
end
```
