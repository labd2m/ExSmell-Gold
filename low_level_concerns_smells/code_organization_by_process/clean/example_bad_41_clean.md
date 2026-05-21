```elixir
defmodule Scheduling.DateRangeCalculator do
  use GenServer

  @moduledoc """
  Provides date-range utilities used by the scheduling service, including
  business-day counting, range overlap detection, and monthly splits for
  payroll and billing period calculations.
  """


  @non_working_days [:saturday, :sunday]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Counts the number of business days between `start_date` and `end_date`
  (inclusive), excluding weekends and any dates in `holidays` list.
  """
  def business_days(pid, start_date, end_date, holidays \\ []) do
    GenServer.call(pid, {:business_days, start_date, end_date, holidays})
  end

  @doc "Returns true if the two date ranges overlap."
  def overlap?(pid, {start1, end1}, {start2, end2}) do
    GenServer.call(pid, {:overlap?, {start1, end1}, {start2, end2}})
  end

  @doc "Splits a date range into a list of `{month_start, month_end}` tuples."
  def split_by_month(pid, start_date, end_date) do
    GenServer.call(pid, {:split_by_month, start_date, end_date})
  end

  @doc "Adds `n` business days to `start_date`, skipping weekends and holidays."
  def add_business_days(pid, start_date, n, holidays \\ []) do
    GenServer.call(pid, {:add_business_days, start_date, n, holidays})
  end

  @doc "Returns the next business day on or after `date`."
  def next_business_day(pid, date, holidays \\ []) do
    GenServer.call(pid, {:next_business_day, date, holidays})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:business_days, start_date, end_date, holidays}, _from, state) do
    count =
      Date.range(start_date, end_date)
      |> Enum.count(fn date ->
        Date.day_of_week(date) not in [6, 7] and date not in holidays
      end)

    {:reply, {:ok, count}, state}
  end

  def handle_call({:overlap?, {s1, e1}, {s2, e2}}, _from, state) do
    overlaps = Date.compare(s1, e2) != :gt and Date.compare(s2, e1) != :gt
    {:reply, overlaps, state}
  end

  def handle_call({:split_by_month, start_date, end_date}, _from, state) do
    months = do_split_by_month(start_date, end_date, [])
    {:reply, {:ok, Enum.reverse(months)}, state}
  end

  def handle_call({:add_business_days, date, n, holidays}, _from, state) do
    result = do_add_business_days(date, n, holidays)
    {:reply, {:ok, result}, state}
  end

  def handle_call({:next_business_day, date, holidays}, _from, state) do
    result = do_next_business_day(date, holidays)
    {:reply, {:ok, result}, state}
  end

  ## Private helpers

  defp do_split_by_month(current, end_date, acc) do
    if Date.compare(current, end_date) == :gt do
      acc
    else
      month_end =
        %{current | day: Date.days_in_month(current)}
        |> Date.min(end_date)

      do_split_by_month(Date.add(month_end, 1), end_date, [{current, month_end} | acc])
    end
  end

  defp do_add_business_days(date, 0, _holidays), do: date
  defp do_add_business_days(date, n, holidays) do
    next = Date.add(date, 1)
    if Date.day_of_week(next) in [6, 7] or next in holidays do
      do_add_business_days(next, n, holidays)
    else
      do_add_business_days(next, n - 1, holidays)
    end
  end

  defp do_next_business_day(date, holidays) do
    if Date.day_of_week(date) in [6, 7] or date in holidays do
      do_next_business_day(Date.add(date, 1), holidays)
    else
      date
    end
  end

end
```
