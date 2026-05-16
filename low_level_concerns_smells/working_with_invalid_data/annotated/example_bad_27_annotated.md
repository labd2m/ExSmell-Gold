# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `PayrollEngine.compute_gross/3`, where `hours_worked` is multiplied by `hourly_rate`
- **Affected function(s):** `compute_gross/3`
- **Short explanation:** The `hours_worked` parameter is used directly in a multiplication with `employee.hourly_rate` without any type validation. Payroll systems frequently ingest hours from timesheets parsed as CSV or JSON where numbers arrive as strings. Passing `"40.5"` instead of `40.5` causes an `ArithmeticError` inside the multiplication deep in `compute_gross/3`, with no message pointing back to the public entry point.

```elixir
defmodule MyApp.HR.PayrollEngine do
  @moduledoc """
  Computes gross and net pay for hourly and salaried employees, applying
  overtime rules, deductions, tax withholding, and benefits contributions.
  """

  require Logger

  alias MyApp.HR.{Employee, DeductionSchedule, TaxWithholding, PayrollRecord, BenefitsLedger}

  @overtime_threshold_hours 40
  @overtime_multiplier 1.5
  @double_time_threshold_hours 60
  @double_time_multiplier 2.0
  @rounding_precision 2

  @type payroll_opts :: [
          period_start: Date.t(),
          period_end: Date.t(),
          include_bonuses: boolean(),
          bonus_amount: number()
        ]

  @spec compute_gross(Employee.t(), term(), payroll_opts()) ::
          {:ok, map()} | {:error, atom()}
  def compute_gross(employee, hours_worked, opts \\ []) do
    period_start = Keyword.get(opts, :period_start, Date.utc_today())
    period_end = Keyword.get(opts, :period_end, Date.utc_today())
    include_bonuses = Keyword.get(opts, :include_bonuses, false)
    bonus_amount = Keyword.get(opts, :bonus_amount, 0.0)

    with :ok <- validate_employee_active(employee) do
      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `hours_worked` is used directly in
      # VALIDATION: arithmetic with `employee.hourly_rate` without checking it is
      # VALIDATION: a number. Timesheet integrations often deserialize hours as
      # VALIDATION: strings. The ArithmeticError will surface inside the
      # VALIDATION: `compute_regular_pay/2` helper, not at this boundary.
      {regular_hours, overtime_hours, double_time_hours} =
        split_hours(hours_worked)

      regular_pay = compute_regular_pay(regular_hours, employee.hourly_rate)
      overtime_pay = compute_overtime_pay(overtime_hours, employee.hourly_rate)
      double_time_pay = compute_double_time_pay(double_time_hours, employee.hourly_rate)
      # VALIDATION: SMELL END

      bonus = if include_bonuses, do: bonus_amount, else: 0.0

      gross_pay =
        Float.round(regular_pay + overtime_pay + double_time_pay + bonus, @rounding_precision)

      {:ok,
       %{
         employee_id: employee.id,
         period_start: period_start,
         period_end: period_end,
         hours_worked: hours_worked,
         regular_hours: regular_hours,
         overtime_hours: overtime_hours,
         double_time_hours: double_time_hours,
         regular_pay: regular_pay,
         overtime_pay: overtime_pay,
         double_time_pay: double_time_pay,
         bonus: bonus,
         gross_pay: gross_pay
       }}
    end
  end

  @spec compute_net(Employee.t(), term(), payroll_opts()) ::
          {:ok, map()} | {:error, atom()}
  def compute_net(employee, hours_worked, opts \\ []) do
    with {:ok, gross} <- compute_gross(employee, hours_worked, opts),
         {:ok, deductions} <- DeductionSchedule.fetch(employee.id),
         {:ok, tax} <- TaxWithholding.compute(employee.id, gross.gross_pay),
         {:ok, benefits} <- BenefitsLedger.employee_contribution(employee.id) do
      total_deductions =
        Enum.sum([
          deductions.total,
          tax.federal,
          tax.state,
          tax.local,
          benefits.health,
          benefits.dental,
          benefits.retirement
        ])

      net_pay = Float.round(gross.gross_pay - total_deductions, @rounding_precision)

      result =
        Map.merge(gross, %{
          tax: tax,
          deductions: deductions,
          benefits_contribution: benefits,
          total_deductions: Float.round(total_deductions, @rounding_precision),
          net_pay: net_pay
        })

      {:ok, result}
    end
  end

  @spec finalize_period([String.t()], Date.t(), Date.t()) ::
          {:ok, %{processed: integer(), failed: integer()}}
  def finalize_period(employee_ids, period_start, period_end) do
    results =
      Enum.map(employee_ids, fn emp_id ->
        with {:ok, employee} <- Employee.fetch(emp_id),
             {:ok, hours} <- fetch_timesheet_hours(emp_id, period_start, period_end),
             {:ok, payroll} <- compute_net(employee, hours, period_start: period_start, period_end: period_end) do
          PayrollRecord.save(payroll)
        end
      end)

    %{
      processed: Enum.count(results, &match?({:ok, _}, &1)),
      failed: Enum.count(results, &match?({:error, _}, &1))
    }
    |> then(&{:ok, &1})
  end

  # Private helpers

  defp validate_employee_active(%{status: :active}), do: :ok
  defp validate_employee_active(_), do: {:error, :employee_inactive}

  defp split_hours(total_hours) do
    cond do
      total_hours > @double_time_threshold_hours ->
        {
          @overtime_threshold_hours,
          @double_time_threshold_hours - @overtime_threshold_hours,
          total_hours - @double_time_threshold_hours
        }

      total_hours > @overtime_threshold_hours ->
        {@overtime_threshold_hours, total_hours - @overtime_threshold_hours, 0}

      true ->
        {total_hours, 0, 0}
    end
  end

  defp compute_regular_pay(hours, rate) do
    Float.round(hours * rate, @rounding_precision)
  end

  defp compute_overtime_pay(hours, rate) do
    Float.round(hours * rate * @overtime_multiplier, @rounding_precision)
  end

  defp compute_double_time_pay(hours, rate) do
    Float.round(hours * rate * @double_time_multiplier, @rounding_precision)
  end

  defp fetch_timesheet_hours(employee_id, period_start, period_end) do
    Logger.debug("Fetching timesheet for #{employee_id}: #{period_start} - #{period_end}")
    {:ok, 40.0}
  end
end
```
