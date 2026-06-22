```elixir
defmodule MyApp.Reporting.DashboardMetrics do
  @moduledoc """
  Computes the key metrics displayed on the operations dashboard. Each
  metric is a named function that runs an independent query so that
  callers can fetch only the metrics they need and parallelise them if
  required. Aggregation windows default to the last 30 days but are
  configurable per call.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Commerce.Order
  alias MyApp.Accounts.User
  alias MyApp.Billing.Payment

  @default_days 30

  @type window_days :: pos_integer()
  @type money_cents :: non_neg_integer()

  @doc "Returns total confirmed revenue in cents for the given window."
  @spec gross_revenue(window_days()) :: money_cents()
  def gross_revenue(days \\ @default_days) do
    since = days_ago(days)

    Payment
    |> where([p], p.status == :captured and p.captured_at >= ^since)
    |> select([p], coalesce(sum(p.amount_cents), 0))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the number of orders placed in the given window."
  @spec order_count(window_days()) :: non_neg_integer()
  def order_count(days \\ @default_days) do
    since = days_ago(days)

    Order
    |> where([o], o.inserted_at >= ^since)
    |> select([o], count(o.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the average order value in cents for the given window."
  @spec average_order_value(window_days()) :: float()
  def average_order_value(days \\ @default_days) do
    since = days_ago(days)

    result =
      Order
      |> where([o], o.status == :completed and o.inserted_at >= ^since)
      |> select([o], avg(o.total_cents))
      |> Repo.one()

    case result do
      nil -> 0.0
      avg -> Float.round(avg * 1.0, 2)
    end
  end

  @doc "Returns the number of new user registrations in the given window."
  @spec new_customers(window_days()) :: non_neg_integer()
  def new_customers(days \\ @default_days) do
    since = days_ago(days)

    User
    |> where([u], u.inserted_at >= ^since)
    |> select([u], count(u.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the order-to-completion rate as a float between 0.0 and 1.0."
  @spec completion_rate(window_days()) :: float()
  def completion_rate(days \\ @default_days) do
    since = days_ago(days)

    result =
      Order
      |> where([o], o.inserted_at >= ^since)
      |> select([o], %{total: count(o.id), completed: filter(count(o.id), o.status == :completed)})
      |> Repo.one()

    case result do
      %{total: 0} -> 0.0
      %{total: t, completed: c} -> Float.round(c / t, 4)
    end
  end

  @doc """
  Returns daily revenue for the given window as a list of
  `%{date, revenue_cents}` maps, ordered chronologically.
  """
  @spec revenue_by_day(window_days()) :: [%{date: Date.t(), revenue_cents: money_cents()}]
  def revenue_by_day(days \\ @default_days) do
    since = days_ago(days)

    Payment
    |> where([p], p.status == :captured and p.captured_at >= ^since)
    |> group_by([p], fragment("DATE(?)", p.captured_at))
    |> order_by([p], asc: fragment("DATE(?)", p.captured_at))
    |> select([p], %{
      date: fragment("DATE(?)", p.captured_at),
      revenue_cents: coalesce(sum(p.amount_cents), 0)
    })
    |> Repo.all()
  end

  @spec days_ago(window_days()) :: DateTime.t()
  defp days_ago(days) do
    DateTime.add(DateTime.utc_now(), -days, :day)
  end
end
```
