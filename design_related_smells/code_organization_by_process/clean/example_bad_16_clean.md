```elixir
defmodule Scheduling.DateUtils do
  use GenServer

  @moduledoc """
  Provides business-day calculation utilities for scheduling, SLA tracking,
  and payment due-date computation. Observes US federal holidays.
  """

  @us_federal_holidays [
    {1, 1},   # New Year's Day
    {7, 4},   # Independence Day
    {11, 11}, # Veterans Day
    {12, 25}  # Christmas Day
  ]

  @floating_holidays %{
    # {month, nth_weekday, day_of_week} — e.g. 3rd Monday of January
    :mlk_day        => {1, 3, 1},
    :presidents_day => {2, 3, 1},
    :memorial_day   => {5, :last, 1},
    :labor_day      => {9, 1, 1},
    :thanksgiving   => {11, 4, 4}
  }



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the number of business days between `from` and `to` (inclusive of `from`).
  """
  def business_days_between(pid, from, to) do
    GenServer.call(pid, {:business_days_between, from, to})
  end

  @doc """
  Adds `n` business days to `date`, skipping weekends and holidays.
  """
  def add_business_days(pid, date, n) do
    GenServer.call(pid, {:add_business_days, date, n})
  end

  @doc """
  Returns the next business day after `date`.
  """
  def next_business_day(pid, date) do
    GenServer.call(pid, {:next_business_day, date})
  end

  @doc """
  Returns `true` if `date` is a business day (not weekend or holiday).
  """
  def is_business_day?(pid, date) do
    GenServer.call(pid, {:is_business_day, date})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:business_days_between, from, to}, _from, state) do
    count =
      Date.range(from, to)
      |> Enum.count(&business_day?/1)

    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:add_business_days, date, n}, _from, state) do
    result = do_add_business_days(date, n)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:next_business_day, date}, _from, state) do
    next =
      date
      |> Date.add(1)
      |> find_next_business_day()

    {:reply, {:ok, next}, state}
  end

  @impl true
  def handle_call({:is_business_day, date}, _from, state) do
    {:reply, {:ok, business_day?(date)}, state}
  end

  defp business_day?(date) do
    dow = Date.day_of_week(date)
    not (dow in [6, 7] or federal_holiday?(date))
  end

  defp federal_holiday?(date) do
    fixed = Enum.any?(@us_federal_holidays, fn {m, d} ->
      date.month == m and date.day == d
    end)

    fixed or observed_monday?(date)
  end

  defp observed_monday?(date) do
    # When a fixed holiday falls on Sunday, it is observed on Monday
    prev = Date.add(date, -1)

    Enum.any?(@us_federal_holidays, fn {m, d} ->
      prev.month == m and prev.day == d and Date.day_of_week(prev) == 7
    end)
  end

  defp do_add_business_days(date, 0), do: date

  defp do_add_business_days(date, n) when n > 0 do
    next = Date.add(date, 1)
    if business_day?(next), do: do_add_business_days(next, n - 1), else: do_add_business_days(next, n)
  end

  defp find_next_business_day(date) do
    if business_day?(date), do: date, else: find_next_business_day(Date.add(date, 1))
  end
end
```
