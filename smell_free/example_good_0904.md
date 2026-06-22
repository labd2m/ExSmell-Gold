# File: `example_good_904.md`

```elixir
defmodule Finance.CashFlowProjector do
  @moduledoc """
  Projects forward-looking cash flows over a configurable horizon by
  combining known scheduled transactions with estimated recurring
  patterns.

  All computation is pure. Supply current balance, scheduled transactions,
  and recurring rules and receive a day-by-day projection with running
  balance, low-balance alerts, and period summaries.
  """

  @type amount_cents :: integer()
  @type date :: Date.t()

  @type scheduled_transaction :: %{
          required(:date) => date(),
          required(:amount_cents) => amount_cents(),
          required(:description) => String.t()
        }

  @type recurring_rule :: %{
          required(:day_of_month) => 1..31,
          required(:amount_cents) => amount_cents(),
          required(:description) => String.t()
        }

  @type daily_projection :: %{
          date: date(),
          transactions: [scheduled_transaction()],
          daily_net_cents: amount_cents(),
          running_balance_cents: amount_cents(),
          low_balance_alert: boolean()
        }

  @type projection_result :: %{
          daily: [daily_projection()],
          period_inflow_cents: amount_cents(),
          period_outflow_cents: amount_cents(),
          period_net_cents: amount_cents(),
          opening_balance_cents: amount_cents(),
          projected_closing_balance_cents: amount_cents(),
          lowest_balance_cents: amount_cents(),
          lowest_balance_date: date() | nil
        }

  @doc """
  Projects cash flows from `start_date` over `horizon_days` calendar days.

  `scheduled` transactions occur on specific dates. `recurring` rules
  generate estimated transactions on their `day_of_month` each month.

  `low_balance_threshold_cents` triggers alerts on daily projections.

  Returns a `projection_result` with full daily detail and period totals.
  """
  @spec project(
          amount_cents(),
          date(),
          pos_integer(),
          [scheduled_transaction()],
          [recurring_rule()],
          amount_cents()
        ) :: projection_result()
  def project(opening_balance_cents, start_date, horizon_days, scheduled, recurring,
              low_balance_threshold_cents \\ 0) do
    end_date = Date.add(start_date, horizon_days - 1)

    all_transactions =
      (scheduled ++ expand_recurring(recurring, start_date, end_date))
      |> Enum.filter(&(Date.compare(&1.date, start_date) != :lt))
      |> Enum.filter(&(Date.compare(&1.date, end_date) != :gt))
      |> Enum.group_by(& &1.date)

    {daily_projections, _final_balance} =
      start_date
      |> Date.range(end_date)
      |> Enum.map_reduce(opening_balance_cents, fn date, balance ->
        day_txns = Map.get(all_transactions, date, [])
        daily_net = Enum.sum(Enum.map(day_txns, & &1.amount_cents))
        new_balance = balance + daily_net

        projection = %{
          date: date,
          transactions: day_txns,
          daily_net_cents: daily_net,
          running_balance_cents: new_balance,
          low_balance_alert: new_balance < low_balance_threshold_cents
        }

        {projection, new_balance}
      end)

    summarise(daily_projections, opening_balance_cents)
  end

  @doc """
  Returns the projected number of days until the balance falls below
  `threshold_cents`, or `nil` when the balance stays above threshold
  throughout the horizon.
  """
  @spec days_until_shortfall([daily_projection()], amount_cents()) :: non_neg_integer() | nil
  def days_until_shortfall(daily_projections, threshold_cents) do
    case Enum.find(daily_projections, &(&1.running_balance_cents < threshold_cents)) do
      nil -> nil
      projection -> Date.diff(projection.date, List.first(daily_projections).date)
    end
  end

  defp expand_recurring(rules, start_date, end_date) do
    months = months_between(start_date, end_date)

    Enum.flat_map(rules, fn rule ->
      Enum.flat_map(months, fn {year, month} ->
        max_day = Date.days_in_month(%Date{year: year, month: month, day: 1})
        day = min(rule.day_of_month, max_day)

        case Date.new(year, month, day) do
          {:ok, date} when date >= start_date and date <= end_date ->
            [%{date: date, amount_cents: rule.amount_cents, description: rule.description}]

          _ ->
            []
        end
      end)
    end)
  end

  defp months_between(start_date, end_date) do
    start_month = {start_date.year, start_date.month}
    end_month = {end_date.year, end_date.month}

    Stream.unfold(start_month, fn {y, m} ->
      if {y, m} > end_month do
        nil
      else
        next = if m == 12, do: {y + 1, 1}, else: {y, m + 1}
        {{y, m}, next}
      end
    end)
    |> Enum.to_list()
  end

  defp summarise(daily, opening_balance_cents) do
    all_amounts = Enum.flat_map(daily, fn d -> Enum.map(d.transactions, & &1.amount_cents) end)
    inflow = all_amounts |> Enum.filter(&(&1 > 0)) |> Enum.sum()
    outflow = all_amounts |> Enum.filter(&(&1 < 0)) |> Enum.sum() |> abs()

    lowest = Enum.min_by(daily, & &1.running_balance_cents, fn -> nil end)
    closing = List.last(daily) |> then(&if &1, do: &1.running_balance_cents, else: opening_balance_cents)

    %{
      daily: daily,
      period_inflow_cents: inflow,
      period_outflow_cents: outflow,
      period_net_cents: inflow - outflow,
      opening_balance_cents: opening_balance_cents,
      projected_closing_balance_cents: closing,
      lowest_balance_cents: lowest && lowest.running_balance_cents,
      lowest_balance_date: lowest && lowest.date
    }
  end
end
```
