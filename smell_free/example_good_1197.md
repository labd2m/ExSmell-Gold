```elixir
defmodule Billing.CycleCalculator do
  @moduledoc """
  Computes billing cycle boundaries, proration amounts, and renewal dates
  for subscriptions with monthly or annual cadences. All calculations are
  purely functional with no side effects.
  """

  alias Finance.Money

  @type cadence :: :monthly | :annual
  @type cycle :: %{
          start_date: Date.t(),
          end_date: Date.t(),
          renewal_date: Date.t(),
          cadence: cadence()
        }

  @spec current_cycle(Date.t(), cadence()) :: cycle()
  def current_cycle(anchor_date, cadence) when is_atom(cadence) do
    today = Date.utc_today()
    start_date = cycle_start(anchor_date, today, cadence)
    end_date = advance_date(start_date, cadence)
    renewal_date = Date.add(end_date, 1)

    %{
      start_date: start_date,
      end_date: Date.add(end_date, -1),
      renewal_date: renewal_date,
      cadence: cadence
    }
  end

  @spec prorate(Money.t(), Date.t(), cadence()) ::
          {:ok, Money.t()} | {:error, :currency_error}
  def prorate(full_price, start_date, cadence) do
    today = Date.utc_today()
    cycle_end = advance_date(today, cadence)
    total_days = Date.diff(cycle_end, start_date)
    remaining_days = Date.diff(cycle_end, today)

    factor = remaining_days / total_days

    case Money.multiply(full_price, factor) do
      {:ok, prorated} -> {:ok, prorated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec renewal_dates(Date.t(), cadence(), pos_integer()) :: [Date.t()]
  def renewal_dates(anchor_date, cadence, count)
      when is_integer(count) and count > 0 do
    Enum.scan(1..count, anchor_date, fn _, date ->
      advance_date(date, cadence)
    end)
  end

  @spec days_remaining(cadence()) :: non_neg_integer()
  def days_remaining(cadence) do
    today = Date.utc_today()
    cycle_end = advance_date(today, cadence)
    Date.diff(cycle_end, today)
  end

  @spec cycle_start(Date.t(), Date.t(), cadence()) :: Date.t()
  defp cycle_start(anchor, today, :monthly) do
    anchor_day = anchor.day
    candidate = %{today | day: min(anchor_day, days_in_month(today))}

    if Date.compare(candidate, today) == :gt do
      prev = Date.add(today, -Date.day_of_week(today))
      %{prev | day: min(anchor_day, days_in_month(prev))}
    else
      candidate
    end
  end

  defp cycle_start(anchor, today, :annual) do
    candidate = %{today | month: anchor.month, day: anchor.day}

    if Date.compare(candidate, today) == :gt do
      %{candidate | year: candidate.year - 1}
    else
      candidate
    end
  end

  @spec advance_date(Date.t(), cadence()) :: Date.t()
  defp advance_date(date, :monthly) do
    next_month = date.month + 1

    case next_month > 12 do
      true -> %{date | year: date.year + 1, month: 1}
      false -> %{date | month: next_month, day: min(date.day, days_in_month(%{date | month: next_month}))}
    end
  end

  defp advance_date(date, :annual) do
    %{date | year: date.year + 1}
  end

  @spec days_in_month(Date.t()) :: pos_integer()
  defp days_in_month(%{year: year, month: month}) do
    :calendar.last_day_of_the_month(year, month)
  end
end
```
