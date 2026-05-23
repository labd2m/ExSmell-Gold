```elixir
defmodule HR.CompensationCalculator do
  @moduledoc """
  Calculates net pay, applies statutory deductions, and generates
  payslip summaries for employees on various pay schedules.
  """

  require Logger

  @valid_pay_periods ["weekly", "biweekly", "monthly", "semi_monthly"]
  @valid_currencies ["USD", "EUR", "GBP", "BRL", "CAD"]
  @pay_period_divisors %{
    "weekly" => 52,
    "biweekly" => 26,
    "semi_monthly" => 24,
    "monthly" => 12
  }

  # Statutory deduction rates (simplified)
  @income_tax_rate 0.22
  @social_security_rate 0.062
  @medicare_rate 0.0145

  @spec calculate_net_pay(String.t(), float(), float(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def calculate_net_pay(employee_id, annual_gross, bonus_percent, currency, pay_period)
      when is_binary(employee_id) and is_float(annual_gross) and
             is_float(bonus_percent) and is_binary(currency) and is_binary(pay_period) do
    with :ok <- validate_currency(currency),
         :ok <- validate_pay_period(pay_period),
         :ok <- validate_gross(annual_gross),
         :ok <- validate_bonus(bonus_percent) do
      divisor = Map.fetch!(@pay_period_divisors, pay_period)
      period_gross = annual_gross / divisor
      bonus_amount = period_gross * bonus_percent
      total_gross = period_gross + bonus_amount

      {:ok, deductions} = apply_deductions(total_gross, currency, pay_period)

      net_pay = total_gross - deductions.total_deductions

      result = %{
        employee_id: employee_id,
        pay_period: pay_period,
        currency: currency,
        period_gross: Float.round(period_gross, 2),
        bonus_amount: Float.round(bonus_amount, 2),
        total_gross: Float.round(total_gross, 2),
        deductions: deductions,
        net_pay: Float.round(net_pay, 2)
      }

      Logger.info("Computed pay for #{employee_id}: #{currency} #{net_pay} (#{pay_period})")
      {:ok, result}
    end
  end

  def calculate_net_pay(_, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec apply_deductions(float(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_deductions(gross_amount, currency, pay_period)
      when is_float(gross_amount) and is_binary(currency) and is_binary(pay_period) do
    income_tax = gross_amount * @income_tax_rate
    social_security = gross_amount * @social_security_rate
    medicare = gross_amount * @medicare_rate
    total = income_tax + social_security + medicare

    {:ok,
     %{
       currency: currency,
       pay_period: pay_period,
       income_tax: Float.round(income_tax, 2),
       social_security: Float.round(social_security, 2),
       medicare: Float.round(medicare, 2),
       total_deductions: Float.round(total, 2)
     }}
  end

  @spec generate_payslip(String.t(), float(), String.t(), String.t()) :: String.t()
  def generate_payslip(employee_id, annual_gross, currency, pay_period) do
    case calculate_net_pay(employee_id, annual_gross, 0.0, currency, pay_period) do
      {:ok, result} ->
        """
        =============================
        PAYSLIP — #{String.upcase(pay_period)}
        =============================
        Employee   : #{employee_id}
        Currency   : #{currency}
        Gross Pay  : #{result.period_gross}
        Income Tax : #{result.deductions.income_tax}
        Soc. Sec.  : #{result.deductions.social_security}
        Medicare   : #{result.deductions.medicare}
        -----------------------------
        NET PAY    : #{result.net_pay}
        =============================
        """

      {:error, reason} ->
        "Payslip unavailable: #{reason}"
    end
  end

  @spec annualise(float(), String.t()) :: {:ok, float()} | {:error, String.t()}
  def annualise(period_amount, pay_period) when is_float(period_amount) and is_binary(pay_period) do
    case Map.fetch(@pay_period_divisors, pay_period) do
      {:ok, divisor} -> {:ok, Float.round(period_amount * divisor, 2)}
      :error -> {:error, "unsupported_pay_period"}
    end
  end

  defp validate_currency(c) when c in @valid_currencies, do: :ok
  defp validate_currency(c), do: {:error, "unsupported_currency: #{c}"}

  defp validate_pay_period(p) when p in @valid_pay_periods, do: :ok
  defp validate_pay_period(p), do: {:error, "invalid_pay_period: #{p}"}

  defp validate_gross(g) when g > 0.0, do: :ok
  defp validate_gross(_), do: {:error, "gross_salary_must_be_positive"}

  defp validate_bonus(b) when b >= 0.0 and b <= 1.0, do: :ok
  defp validate_bonus(_), do: {:error, "bonus_percent_must_be_between_0_and_1"}
end
```
