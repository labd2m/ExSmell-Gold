```elixir
defmodule MyApp.HR.PayrollProcessor do
  @moduledoc """
  Computes payslips for all active employees in a given payroll period.
  Handles base salary, overtime, tax withholding, and commission.
  """

  alias MyApp.HR.{Employee, Contract, Payslip}
  alias MyApp.Finance.{TaxCalculator, BankTransfer}
  alias MyApp.Notifications.PayslipMailer

  @overtime_multiplier 1.5

  def run(period_start, period_end) do
    employees = Employee.list_active()

    results =
      Enum.map(employees, fn emp ->
        case process_employee(emp, period_start, period_end) do
          {:ok, payslip}   -> {:ok, emp.id, payslip}
          {:error, reason} -> {:error, emp.id, reason}
        end
      end)

    successes = Enum.count(results, &match?({:ok, _, _}, &1))
    failures  = Enum.count(results, &match?({:error, _, _}, &1))

    {:ok, %{period_start: period_start, period_end: period_end, succeeded: successes, failed: failures}}
  end

  def process_employee(employee_id, period_start, period_end) when is_binary(employee_id) do
    case Employee.fetch(employee_id) do
      {:ok, emp} -> process_employee(emp, period_start, period_end)
      error      -> error
    end
  end

  def process_employee(employee, period_start, period_end) do
    contract = Contract.active_for(employee.id)

    base_salary       = employee.base_salary
    overtime_hours    = employee.overtime_hours
    withholding_code  = employee.tax_withholding_code

    pay_frequency     = contract.pay_frequency
    bonus_eligible    = contract.bonus_eligible
    commission_rate   = contract.commission_rate

    hourly_rate   = annual_to_hourly(base_salary, pay_frequency)
    overtime_pay  = hourly_rate * @overtime_multiplier * overtime_hours
    sales_revenue = Employee.sales_revenue(employee.id, period_start, period_end)
    commission    = if bonus_eligible, do: sales_revenue * commission_rate, else: 0.0

    gross          = base_salary / frequency_divisor(pay_frequency) + overtime_pay + commission
    tax            = TaxCalculator.compute(gross, withholding_code)
    net            = gross - tax

    payslip = %{
      id:            generate_id(),
      employee_id:   employee.id,
      period_start:  period_start,
      period_end:    period_end,
      gross_pay:     Float.round(gross, 2),
      tax_withheld:  Float.round(tax, 2),
      net_pay:       Float.round(net, 2),
      overtime_pay:  Float.round(overtime_pay, 2),
      commission:    Float.round(commission, 2),
      status:        :pending,
      created_at:    DateTime.utc_now()
    }

    case Payslip.save(payslip) do
      {:ok, saved} ->
        BankTransfer.schedule(employee.bank_account, saved.net_pay, period_end)
        PayslipMailer.deliver(employee, saved)
        {:ok, saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_payslips(employee_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    :ets.tab2list(:payslips)
    |> Enum.map(fn {_, p} -> p end)
    |> Enum.filter(&(&1.employee_id == employee_id))
    |> Enum.sort_by(& &1.period_end, {:desc, DateTime})
    |> Enum.take(limit)
  end


  defp annual_to_hourly(annual, :weekly),     do: annual / 52 / 40
  defp annual_to_hourly(annual, :biweekly),   do: annual / 26 / 80
  defp annual_to_hourly(annual, :monthly),    do: annual / 12 / 160
  defp annual_to_hourly(annual, _),           do: annual / 52 / 40

  defp frequency_divisor(:weekly),  do: 52
  defp frequency_divisor(:biweekly), do: 26
  defp frequency_divisor(:monthly),  do: 12
  defp frequency_divisor(_),          do: 52

  defp generate_id do
    "PAY-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
