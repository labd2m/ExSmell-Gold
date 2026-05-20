# Annotated Example — Smell: Unrelated multi-clause function

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ReportBuilder.generate/1`
- **Affected function(s):** `generate/1`
- **Short explanation:** The `generate/1` function uses pattern matching to bundle three conceptually different report types — a financial summary, a user activity audit, and an inventory snapshot — into a single function. Each clause queries different data, applies different formatting and aggregation logic, and targets different consumers. They have no shared logic and should be distinct, individually documented functions.

---

```elixir
defmodule MyApp.ReportBuilder do
  @moduledoc """
  Builds and exports various reports for internal business use.
  Supports financial summaries, user activity audits, and inventory snapshots.
  """

  require Logger

  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Finance.{Transaction, Invoice}
  alias MyApp.Accounts.{User, AuditLog}
  alias MyApp.Inventory.{Product, StockLevel}
  alias MyApp.Reports.ExportStorage

  @doc """
  Generates a report and stores it for retrieval.

  Accepts one of:
  - `%{type: :financial_summary, from: date, to: date, currency: currency}`
  - `%{type: :user_activity_audit, from: date, to: date, role: role}`
  - `%{type: :inventory_snapshot, warehouse_id: id}`

  ## Examples

      iex> MyApp.ReportBuilder.generate(%{type: :financial_summary, from: ~D[2024-01-01], to: ~D[2024-03-31], currency: "USD"})
      {:ok, %{report_id: "rpt_abc123", url: "https://..."}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because the three clauses generate completely
  # unrelated reports (financial, audit, inventory), each querying different
  # schemas, applying different aggregation rules, and serving different business
  # consumers. They share a verb ("generate") but no logic or data path.

  def generate(%{type: :financial_summary, from: from_date, to: to_date, currency: currency}) do
    Logger.info("Generating financial summary report #{from_date} to #{to_date} [#{currency}]")

    transactions =
      Repo.all(
        from t in Transaction,
          where: t.currency == ^currency,
          where: t.inserted_at >= ^NaiveDateTime.new!(from_date, ~T[00:00:00]),
          where: t.inserted_at <= ^NaiveDateTime.new!(to_date, ~T[23:59:59]),
          select: %{amount: t.amount, type: t.type, status: t.status, inserted_at: t.inserted_at}
      )

    invoices =
      Repo.all(
        from i in Invoice,
          where: i.currency == ^currency,
          where: i.issued_at >= ^from_date and i.issued_at <= ^to_date,
          select: %{total: i.total, status: i.status, issued_at: i.issued_at}
      )

    summary = %{
      total_revenue: sum_by_type(transactions, :credit),
      total_refunds: sum_by_type(transactions, :refund),
      outstanding_invoices: count_by_status(invoices, :pending),
      paid_invoices: count_by_status(invoices, :paid),
      currency: currency,
      period: "#{from_date} to #{to_date}"
    }

    report_id = generate_report_id()
    {:ok, url} = ExportStorage.store(report_id, :financial_summary, summary)
    Logger.info("Financial summary report #{report_id} stored at #{url}")
    {:ok, %{report_id: report_id, url: url}}
  end

  def generate(%{type: :user_activity_audit, from: from_date, to: to_date, role: role}) do
    Logger.info("Generating user activity audit for role=#{role}, #{from_date} to #{to_date}")

    users =
      Repo.all(from u in User, where: u.role == ^role, select: %{id: u.id, email: u.email})

    user_ids = Enum.map(users, & &1.id)

    audit_logs =
      Repo.all(
        from a in AuditLog,
          where: a.user_id in ^user_ids,
          where: a.occurred_at >= ^NaiveDateTime.new!(from_date, ~T[00:00:00]),
          where: a.occurred_at <= ^NaiveDateTime.new!(to_date, ~T[23:59:59]),
          order_by: [asc: a.user_id, asc: a.occurred_at],
          select: %{
            user_id: a.user_id,
            action: a.action,
            resource: a.resource,
            ip_address: a.ip_address,
            occurred_at: a.occurred_at
          }
      )

    entries_by_user =
      Enum.group_by(audit_logs, & &1.user_id)

    report_rows =
      Enum.map(users, fn user ->
        logs = Map.get(entries_by_user, user.id, [])
        %{user: user, total_actions: length(logs), logs: logs}
      end)

    report_id = generate_report_id()
    {:ok, url} = ExportStorage.store(report_id, :user_activity_audit, report_rows)
    Logger.info("User activity audit report #{report_id} stored at #{url}")
    {:ok, %{report_id: report_id, url: url}}
  end

  def generate(%{type: :inventory_snapshot, warehouse_id: warehouse_id}) do
    Logger.info("Generating inventory snapshot for warehouse #{warehouse_id}")

    stock_levels =
      Repo.all(
        from s in StockLevel,
          join: p in Product,
          on: p.id == s.product_id,
          where: s.warehouse_id == ^warehouse_id,
          select: %{
            sku: p.sku,
            name: p.name,
            category: p.category,
            quantity: s.quantity,
            reserved: s.reserved,
            available: s.quantity - s.reserved,
            reorder_point: p.reorder_point,
            unit_cost: p.unit_cost
          }
      )

    low_stock = Enum.filter(stock_levels, fn s -> s.available <= s.reorder_point end)
    total_value = Enum.reduce(stock_levels, 0.0, fn s, acc -> acc + s.quantity * s.unit_cost end)

    report = %{
      warehouse_id: warehouse_id,
      snapshot_at: DateTime.utc_now(),
      total_skus: length(stock_levels),
      low_stock_skus: length(low_stock),
      total_inventory_value: Float.round(total_value, 2),
      items: stock_levels
    }

    report_id = generate_report_id()
    {:ok, url} = ExportStorage.store(report_id, :inventory_snapshot, report)
    Logger.info("Inventory snapshot report #{report_id} stored at #{url}")
    {:ok, %{report_id: report_id, url: url}}
  end

  # VALIDATION: SMELL END

  defp sum_by_type(transactions, type) do
    transactions
    |> Enum.filter(&(&1.type == type and &1.status == :completed))
    |> Enum.reduce(0.0, &(&1.amount + &2))
  end

  defp count_by_status(invoices, status) do
    Enum.count(invoices, &(&1.status == status))
  end

  defp generate_report_id do
    "rpt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
```
