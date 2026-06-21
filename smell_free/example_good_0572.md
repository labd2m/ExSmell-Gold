```elixir
defmodule Billing.Cycle do
  @moduledoc false

  @type interval :: :monthly | :annual

  @type t :: %__MODULE__{
          interval: interval(),
          starts_on: Date.t(),
          ends_on: Date.t(),
          amount_cents: non_neg_integer(),
          currency: String.t()
        }

  defstruct [:interval, :starts_on, :ends_on, :amount_cents, :currency]
end

defmodule Billing.CycleCalculator do
  @moduledoc """
  Calculates subscription billing cycles, renewal dates, and prorated
  amounts when a subscription changes mid-cycle.

  Proration is computed as the fraction of unused days remaining in the
  current cycle multiplied by the period price. This ensures customers
  only pay for the portion of a billing period they actually use when
  upgrading, downgrading, or cancelling mid-cycle.
  """

  alias Billing.Cycle

  @spec current_cycle(Date.t(), Cycle.interval()) :: {Date.t(), Date.t()}
  def current_cycle(%Date{} = anchor, :monthly) do
    today = Date.utc_today()
    start = find_cycle_start(today, anchor, :monthly)
    {start, Date.add(Date.end_of_month(start), 0)}
  end

  def current_cycle(%Date{} = anchor, :annual) do
    today = Date.utc_today()
    year = today.year
    candidate = %{anchor | year: year}

    start =
      cond do
        Date.compare(candidate, today) == :gt -> %{anchor | year: year - 1}
        true -> candidate
      end

    {start, %{start | year: start.year + 1} |> Date.add(-1)}
  end

  @spec next_renewal(Date.t(), Cycle.interval()) :: Date.t()
  def next_renewal(%Date{} = anchor, :monthly) do
    {_, period_end} = current_cycle(anchor, :monthly)
    Date.add(period_end, 1)
  end

  def next_renewal(%Date{} = anchor, :annual) do
    {_, period_end} = current_cycle(anchor, :annual)
    Date.add(period_end, 1)
  end

  @spec prorated_amount(non_neg_integer(), Date.t(), Cycle.interval()) :: non_neg_integer()
  def prorated_amount(full_amount_cents, %Date{} = anchor, interval) do
    today = Date.utc_today()
    {cycle_start, cycle_end} = current_cycle(anchor, interval)
    total_days = Date.diff(cycle_end, cycle_start) + 1
    remaining_days = Date.diff(cycle_end, today) + 1

    if remaining_days <= 0 do
      0
    else
      round(full_amount_cents * remaining_days / total_days)
    end
  end

  @spec days_until_renewal(Date.t(), Cycle.interval()) :: non_neg_integer()
  def days_until_renewal(%Date{} = anchor, interval) do
    renewal = next_renewal(anchor, interval)
    max(0, Date.diff(renewal, Date.utc_today()))
  end

  @spec cycles_between(Date.t(), Date.t(), Cycle.interval()) :: non_neg_integer()
  def cycles_between(%Date{} = from, %Date{} = to, :monthly) do
    months = (to.year - from.year) * 12 + (to.month - from.month)
    max(0, months)
  end

  def cycles_between(%Date{} = from, %Date{} = to, :annual) do
    max(0, to.year - from.year)
  end

  defp find_cycle_start(%Date{} = today, %Date{} = anchor, :monthly) do
    candidate = %{today | day: min(anchor.day, days_in_month(today))}

    if Date.compare(candidate, today) == :gt do
      prev = Date.add(today, -Date.day_of_year(today))
      %{prev | day: min(anchor.day, days_in_month(prev))}
    else
      candidate
    end
  end

  defp days_in_month(%Date{year: y, month: m}) do
    Date.days_in_month(%Date{year: y, month: m, day: 1})
  end
end
```
