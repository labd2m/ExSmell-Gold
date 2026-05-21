```elixir
defmodule Payroll.GrossPayCalculator do
  use GenServer

  @moduledoc """
  Computes gross pay for employees across multiple compensation types:
  hourly, salaried, and commission-based. Used by the payroll processing
  pipeline when generating payslips at the end of each pay period.
  """


  @overtime_threshold_hours 40.0
  @overtime_multiplier      1.5
  @double_time_threshold    60.0
  @double_time_multiplier   2.0

  @pay_period_divisors %{
    weekly:      52,
    biweekly:    26,
    semimonthly: 24,
    monthly:     12
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Calculates gross pay for `employee` over `period`.

  `employee` map keys:
    - `:type`            — `:hourly | :salaried | :commission`
    - `:hourly_rate`     — float (for hourly employees)
    - `:annual_salary`   — float (for salaried employees)
    - `:commission_rate` — float 0..1 (for commission employees)
    - `:base_annual`     — float (commission base salary)
    - `:pay_period`      — atom (`:weekly | :biweekly | :semimonthly | :monthly`)

  `period` map keys:
    - `:hours_worked`    — float (hourly)
    - `:sales_amount`    — float (commission)
    - `:bonuses`         — list of `%{type: atom, amount: float}`

  Returns `{:ok, pay_breakdown_map}` or `{:error, reason}`.
  """
  def calculate(pid, employee, period) do
    GenServer.call(pid, {:calculate, employee, period})
  end

  @doc """
  Returns `{:ok, overtime_pay}` for `hours_worked` at `hourly_rate`,
  applying standard and double-time thresholds.
  """
  def overtime_pay(pid, hours_worked, hourly_rate) do
    GenServer.call(pid, {:overtime_pay, hours_worked, hourly_rate})
  end

  @doc """
  Returns `{:ok, bonus_total}` for a list of bonus entries.
  Bonus entry: `%{type: :fixed | :percentage, amount: float, base: float}`.
  """
  def bonus_amount(pid, bonuses, base_pay) do
    GenServer.call(pid, {:bonus_amount, bonuses, base_pay})
  end

  @doc "Converts an annual salary to a single period amount."
  def annual_to_period(pid, annual_salary, pay_period) do
    GenServer.call(pid, {:annual_to_period, annual_salary, pay_period})
  end

  @doc "Returns a breakdown of regular, overtime, and double-time hours."
  def hours_breakdown(pid, hours_worked) do
    GenServer.call(pid, {:hours_breakdown, hours_worked})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:calculate, employee, period}, _from, state) do
    result =
      case employee.type do
        :hourly    -> compute_hourly(employee, period)
        :salaried  -> compute_salaried(employee, period)
        :commission -> compute_commission(employee, period)
        _          -> {:error, :unknown_employment_type}
      end

    {:reply, result, state}
  end

  def handle_call({:overtime_pay, hours, rate}, _from, state) do
    {regular, overtime, double_time} = split_hours(hours)
    ot_pay =
      overtime * rate * @overtime_multiplier +
      double_time * rate * @double_time_multiplier

    _ = regular
    {:reply, {:ok, Float.round(ot_pay, 2)}, state}
  end

  def handle_call({:bonus_amount, bonuses, base_pay}, _from, state) do
    total =
      Enum.reduce(bonuses, 0.0, fn bonus, acc ->
        case bonus.type do
          :fixed      -> acc + bonus.amount
          :percentage -> acc + base_pay * bonus.amount
          _           -> acc
        end
      end)

    {:reply, {:ok, Float.round(total, 2)}, state}
  end

  def handle_call({:annual_to_period, annual, pay_period}, _from, state) do
    result =
      case Map.get(@pay_period_divisors, pay_period) do
        nil     -> {:error, :unknown_pay_period}
        divisor -> {:ok, Float.round(annual / divisor, 2)}
      end

    {:reply, result, state}
  end

  def handle_call({:hours_breakdown, hours}, _from, state) do
    {regular, overtime, double_time} = split_hours(hours)

    breakdown = %{
      regular:     Float.round(regular, 2),
      overtime:    Float.round(overtime, 2),
      double_time: Float.round(double_time, 2)
    }

    {:reply, {:ok, breakdown}, state}
  end

  ## Private helpers

  defp compute_hourly(employee, period) do
    hours = Map.get(period, :hours_worked, 0.0)
    rate  = employee.hourly_rate

    {regular_h, overtime_h, double_h} = split_hours(hours)

    regular_pay     = regular_h * rate
    overtime_pay    = overtime_h * rate * @overtime_multiplier
    double_time_pay = double_h * rate * @double_time_multiplier
    base_pay        = regular_pay + overtime_pay + double_time_pay

    bonus  = compute_bonuses(Map.get(period, :bonuses, []), base_pay)
    gross  = Float.round(base_pay + bonus, 2)

    {:ok, %{
      type:            :hourly,
      regular_pay:     Float.round(regular_pay, 2),
      overtime_pay:    Float.round(overtime_pay, 2),
      double_time_pay: Float.round(double_time_pay, 2),
      bonus:           Float.round(bonus, 2),
      gross_pay:       gross
    }}
  end

  defp compute_salaried(employee, period) do
    divisor    = Map.get(@pay_period_divisors, employee.pay_period, 26)
    period_pay = Float.round(employee.annual_salary / divisor, 2)
    bonus      = compute_bonuses(Map.get(period, :bonuses, []), period_pay)
    gross      = Float.round(period_pay + bonus, 2)

    {:ok, %{
      type:       :salaried,
      period_pay: period_pay,
      bonus:      Float.round(bonus, 2),
      gross_pay:  gross
    }}
  end

  defp compute_commission(employee, period) do
    divisor   = Map.get(@pay_period_divisors, employee.pay_period, 26)
    base      = Float.round(employee.base_annual / divisor, 2)
    sales     = Map.get(period, :sales_amount, 0.0)
    comm_pay  = Float.round(sales * employee.commission_rate, 2)
    bonus     = compute_bonuses(Map.get(period, :bonuses, []), base + comm_pay)
    gross     = Float.round(base + comm_pay + bonus, 2)

    {:ok, %{
      type:            :commission,
      base_pay:        base,
      commission_pay:  comm_pay,
      bonus:           Float.round(bonus, 2),
      gross_pay:       gross
    }}
  end

  defp split_hours(hours) do
    regular     = min(hours, @overtime_threshold_hours)
    overtime    = min(max(hours - @overtime_threshold_hours, 0.0), @double_time_threshold - @overtime_threshold_hours)
    double_time = max(hours - @double_time_threshold, 0.0)
    {regular, overtime, double_time}
  end

  defp compute_bonuses(bonuses, base_pay) do
    Enum.reduce(bonuses, 0.0, fn bonus, acc ->
      case bonus.type do
        :fixed      -> acc + bonus.amount
        :percentage -> acc + base_pay * bonus.amount
        _           -> acc
      end
    end)
  end

end
```
