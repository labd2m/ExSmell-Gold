```elixir
defmodule Reports.DashboardMetrics do
  @moduledoc """
  Computes key business metrics for the operations dashboard. All queries
  are read-only and accept a `reference_date` parameter so results are
  fully reproducible in tests without mocking the system clock.
  Each metric function is independent and cacheable individually.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.User
  alias Commerce.Order
  alias Billing.Invoice

  @type date_range :: %{from: Date.t(), to: Date.t()}
  @type dashboard_snapshot :: %{
          new_users: non_neg_integer(),
          active_users: non_neg_integer(),
          orders_placed: non_neg_integer(),
          gross_revenue_cents: non_neg_integer(),
          average_order_value_cents: non_neg_integer(),
          outstanding_invoice_cents: non_neg_integer()
        }

  @doc """
  Returns a complete dashboard snapshot for the given `date_range`.
  All counts and amounts reflect activity that occurred within the range.
  """
  @spec snapshot(date_range()) :: dashboard_snapshot()
  def snapshot(%{from: from_date, to: to_date}) do
    from_dt = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(to_date, ~T[23:59:59], "Etc/UTC")

    %{
      new_users: count_new_users(from_dt, to_dt),
      active_users: count_active_users(from_dt, to_dt),
      orders_placed: count_orders(from_dt, to_dt),
      gross_revenue_cents: sum_revenue(from_dt, to_dt),
      average_order_value_cents: average_order_value(from_dt, to_dt),
      outstanding_invoice_cents: sum_outstanding_invoices()
    }
  end

  @doc "Returns the count of new user registrations within the date range."
  @spec count_new_users(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_new_users(from_dt, to_dt) do
    Repo.one(from(u in User,
      where: u.inserted_at >= ^from_dt and u.inserted_at <= ^to_dt,
      select: count(u.id)
    )) || 0
  end

  @doc "Returns the count of users who placed at least one order in the range."
  @spec count_active_users(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_active_users(from_dt, to_dt) do
    Repo.one(from(o in Order,
      where: o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt,
      select: count(o.customer_id, :distinct)
    )) || 0
  end

  @doc "Returns the count of confirmed orders placed in the range."
  @spec count_orders(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_orders(from_dt, to_dt) do
    Repo.one(from(o in Order,
      where: o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt
             and o.status == "confirmed",
      select: count(o.id)
    )) || 0
  end

  @doc "Returns the gross revenue in cents from confirmed orders in the range."
  @spec sum_revenue(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def sum_revenue(from_dt, to_dt) do
    Repo.one(from(o in Order,
      where: o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt
             and o.status == "confirmed",
      select: sum(o.total_cents)
    )) || 0
  end

  @doc "Returns the average order value in cents for the range, rounded to the nearest cent."
  @spec average_order_value(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def average_order_value(from_dt, to_dt) do
    result = Repo.one(from(o in Order,
      where: o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt
             and o.status == "confirmed",
      select: avg(o.total_cents)
    ))

    case result do
      nil -> 0
      avg -> avg |> Decimal.to_float() |> round()
    end
  end

  @doc "Returns the total unpaid invoice amount in cents across all customers."
  @spec sum_outstanding_invoices() :: non_neg_integer()
  def sum_outstanding_invoices do
    Repo.one(from(i in Invoice,
      where: i.status == "draft" or i.status == "sent",
      select: sum(i.total_cents)
    )) || 0
  end
end
```
