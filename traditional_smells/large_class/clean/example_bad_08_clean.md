```elixir
defmodule MyApp.ReportingEngine do
  @moduledoc """
  Generates, exports, schedules, and delivers reports across all
  business domains: sales, revenue, users, inventory, and support.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Orders.Order
  alias MyApp.Accounts.User
  alias MyApp.Billing.{Invoice, Subscription}
  alias MyApp.Inventory.StockItem
  alias MyApp.Support.Ticket
  alias MyApp.Reporting.{ScheduledReport, ReportDelivery}


  def sales_summary(start_date, end_date) do
    orders =
      from(o in Order,
        where: o.placed_at >= ^start_date and o.placed_at <= ^end_date
          and o.status not in [:canceled],
        preload: [:items]
      )
      |> Repo.all()

    by_day =
      orders
      |> Enum.group_by(&Date.to_string(DateTime.to_date(&1.placed_at)))
      |> Map.new(fn {day, day_orders} ->
        {day, %{
          count:    length(day_orders),
          revenue:  Enum.sum(Enum.map(day_orders, & &1.total))
        }}
      end)

    %{
      period:        "#{start_date} to #{end_date}",
      total_orders:  length(orders),
      total_revenue: Enum.sum(Enum.map(orders, & &1.total)),
      avg_order_value: if(Enum.empty?(orders), do: 0,
                        else: div(Enum.sum(Enum.map(orders, & &1.total)), length(orders))),
      by_day: by_day
    }
  end

  def revenue_by_product(start_date, end_date) do
    from(oi in MyApp.Orders.OrderItem,
      join: o in Order, on: o.id == oi.order_id,
      join: p in MyApp.Products.Product, on: p.id == oi.product_id,
      where: o.placed_at >= ^start_date and o.placed_at <= ^end_date
        and o.status not in [:canceled],
      group_by: [p.id, p.name, p.sku],
      select: %{
        product_id:  p.id,
        sku:         p.sku,
        name:        p.name,
        units_sold:  sum(oi.quantity),
        revenue:     sum(oi.line_total)
      },
      order_by: [desc: sum(oi.line_total)]
    )
    |> Repo.all()
  end


  def user_acquisition_report(start_date, end_date) do
    new_users =
      from(u in User,
        where: u.inserted_at >= ^start_date and u.inserted_at <= ^end_date,
        select: %{id: u.id, email: u.email, created_at: u.inserted_at, source: u.acquisition_source}
      )
      |> Repo.all()

    by_source =
      Enum.group_by(new_users, & &1.source)
      |> Map.new(fn {src, users} -> {src, length(users)} end)

    %{total_new_users: length(new_users), by_source: by_source, users: new_users}
  end

  def churn_report(start_date, end_date) do
    canceled_subs =
      from(s in Subscription,
        where: s.canceled_at >= ^start_date and s.canceled_at <= ^end_date,
        preload: [:user]
      )
      |> Repo.all()

    total_active_start =
      from(s in Subscription,
        where: s.status == :active and s.inserted_at <= ^start_date
      )
      |> Repo.aggregate(:count, :id)

    churn_rate =
      if total_active_start > 0,
        do: Float.round(length(canceled_subs) / total_active_start * 100, 2),
        else: 0.0

    reasons =
      Enum.group_by(canceled_subs, & &1.cancel_reason)
      |> Map.new(fn {reason, list} -> {reason, length(list)} end)

    %{
      canceled:           length(canceled_subs),
      active_at_start:    total_active_start,
      churn_rate_percent: churn_rate,
      by_reason:          reasons
    }
  end


  def inventory_turnover(start_date, end_date) do
    movements =
      from(ml in MyApp.Inventory.MovementLog,
        where: ml.movement_type == :fulfillment
          and ml.occurred_at >= ^start_date and ml.occurred_at <= ^end_date,
        group_by: ml.product_id,
        select: %{product_id: ml.product_id, units_sold: sum(ml.quantity)}
      )
      |> Repo.all()

    Enum.map(movements, fn mv ->
      stock = Repo.get_by(StockItem, product_id: mv.product_id)
      avg_inventory = if stock, do: stock.quantity_on_hand, else: 0

      turnover =
        if avg_inventory > 0,
          do: Float.round(mv.units_sold / avg_inventory, 2),
          else: 0.0

      Map.put(mv, :turnover_ratio, turnover)
    end)
    |> Enum.sort_by(& &1.turnover_ratio, :desc)
  end


  def support_ticket_summary(start_date, end_date) do
    tickets =
      from(t in Ticket,
        where: t.inserted_at >= ^start_date and t.inserted_at <= ^end_date
      )
      |> Repo.all()

    resolved    = Enum.filter(tickets, &(&1.status == :resolved))
    avg_resolve =
      if Enum.empty?(resolved) do
        nil
      else
        total_seconds =
          Enum.sum(Enum.map(resolved, fn t ->
            DateTime.diff(t.resolved_at, t.inserted_at)
          end))
        div(total_seconds, length(resolved))
      end

    %{
      total:              length(tickets),
      open:               Enum.count(tickets, &(&1.status == :open)),
      resolved:           length(resolved),
      avg_resolution_sec: avg_resolve,
      by_priority: Enum.group_by(tickets, & &1.priority)
                   |> Map.new(fn {p, ts} -> {p, length(ts)} end)
    }
  end


  def export_to_csv(report_data, headers) when is_list(report_data) do
    header_row = Enum.join(headers, ",") <> "\n"

    rows =
      Enum.map(report_data, fn row ->
        values = Enum.map(headers, fn h ->
          val = Map.get(row, String.to_atom(h), "")
          "\"#{val}\""
        end)
        Enum.join(values, ",") <> "\n"
      end)

    header_row <> Enum.join(rows)
  end

  def export_to_json(report_data) do
    Jason.encode!(report_data, pretty: true)
  end


  def schedule_report(report_type, recurrence, recipients) do
    Repo.insert(%ScheduledReport{
      report_type: report_type,
      recurrence:  recurrence,
      recipients:  recipients,
      next_run_at: next_run_for(recurrence),
      status:      :active
    })
  end

  defp next_run_for(:daily),   do: DateTime.add(DateTime.utc_now(), 86_400, :second)
  defp next_run_for(:weekly),  do: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
  defp next_run_for(:monthly), do: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)


  def deliver_report(%ScheduledReport{} = sr, report_content) do
    Enum.each(sr.recipients, fn email ->
      MyApp.Mailer.deliver(%{
        to:      email,
        subject: "Scheduled Report: #{sr.report_type}",
        body:    "Please find the attached report.",
        attachments: [%{name: "report.csv", data: report_content}]
      })
    end)

    Repo.insert!(%ReportDelivery{
      scheduled_report_id: sr.id,
      delivered_at:        DateTime.utc_now(),
      recipient_count:     length(sr.recipients)
    })

    Repo.update!(ScheduledReport.changeset(sr, %{
      last_run_at: DateTime.utc_now(),
      next_run_at: next_run_for(sr.recurrence)
    }))

    :ok
  end
end
```
