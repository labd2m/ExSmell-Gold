# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Payroll.Calculator.compute_payslip/2`
- **Affected function(s):** `compute_payslip/2`
- **Short explanation:** The `:format` option changes the return from a `%Payslip{}` struct, to a JSON-encoded binary string, to a keyword list of labelled amounts. These are three structurally incompatible types that force every caller to know which format was selected before touching the result.

---

```elixir
defmodule MyApp.Payroll.Calculator do
  @moduledoc """
  Computes employee payslips including gross pay, deductions (tax, social
  security, benefits), and net pay. Handles hourly, salaried, and
  commission-based compensation models.
  """

  alias MyApp.Payroll.TaxTable
  alias MyApp.Payroll.BenefitsLedger
  alias MyApp.Payroll.CommissionEngine
  alias MyApp.Payroll.Compliance

  @inss_rate Decimal.new("0.09")
  @default_currency "BRL"

  defstruct [
    :employee_id, :period_start, :period_end,
    :gross_pay, :deductions, :net_pay,
    :currency, :breakdown, :generated_at
  ]

  def new_period(start_date, end_date) do
    %{start: start_date, end: end_date, days: Date.diff(end_date, start_date) + 1}
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:format] changes the return type
  # completely: :struct returns a %Payslip{} struct (used by the payroll
  # service layer), :json returns a JSON binary string (used for API responses
  # and file generation), and :ledger returns a keyword list of labelled
  # Decimal amounts (used for accounting integrations). No single pattern-match
  # can cover all three, and callers must track the option to safely consume
  # the result.
  def compute_payslip(employee_id, opts \\ []) when is_list(opts) do
    format = Keyword.get(opts, :format, :struct)
    period = Keyword.get(opts, :period, current_period())
    currency = Keyword.get(opts, :currency, @default_currency)
    include_commission = Keyword.get(opts, :include_commission, false)

    base_salary = BenefitsLedger.base_salary(employee_id)

    commission =
      if include_commission do
        CommissionEngine.compute(employee_id, period)
      else
        Decimal.new(0)
      end

    gross = Decimal.add(base_salary, commission)
    inss = Decimal.mult(gross, @inss_rate)
    irrf = TaxTable.irrf(gross, currency)
    benefit_deductions = BenefitsLedger.deductions(employee_id)
    total_deductions = Decimal.add(inss, Decimal.add(irrf, benefit_deductions))
    net = Decimal.sub(gross, total_deductions)

    :ok = Compliance.validate_net_pay(net, currency)

    case format do
      :struct ->
        %__MODULE__{
          employee_id: employee_id,
          period_start: period.start,
          period_end: period.end,
          gross_pay: gross,
          deductions: %{inss: inss, irrf: irrf, benefits: benefit_deductions, total: total_deductions},
          net_pay: net,
          currency: currency,
          breakdown: %{base_salary: base_salary, commission: commission},
          generated_at: DateTime.utc_now()
        }

      :json ->
        Jason.encode!(%{
          employee_id: employee_id,
          period: "#{period.start}/#{period.end}",
          gross_pay: Decimal.to_string(gross),
          deductions: %{
            inss: Decimal.to_string(inss),
            irrf: Decimal.to_string(irrf),
            benefits: Decimal.to_string(benefit_deductions)
          },
          net_pay: Decimal.to_string(net),
          currency: currency
        })

      :ledger ->
        [
          gross_pay: gross,
          inss_deduction: inss,
          irrf_deduction: irrf,
          benefits_deduction: benefit_deductions,
          total_deductions: total_deductions,
          net_pay: net
        ]
    end
  end
  # VALIDATION: SMELL END

  def batch_compute(employee_ids, opts \\ []) do
    Enum.map(employee_ids, fn id ->
      {id, compute_payslip(id, opts)}
    end)
  end

  def ytd_summary(employee_id, year) do
    periods = BenefitsLedger.periods_for_year(employee_id, year)
    Enum.reduce(periods, Decimal.new(0), fn period, acc ->
      slip = compute_payslip(employee_id, period: period, format: :struct)
      Decimal.add(acc, slip.net_pay)
    end)
  end

  defp current_period do
    today = Date.utc_today()
    start = Date.beginning_of_month(today)
    %{start: start, end: today}
  end
end
```
