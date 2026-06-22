```elixir
defmodule Hrm.Payroll.SalaryCalculator do
  @moduledoc """
  Computes gross and net salary for employees based on contract type,
  tax bracket lookups, and optional benefit deductions.
  All values are represented in integer cents to avoid floating-point drift.
  """

  alias Hrm.Payroll.{Contract, TaxTable, BenefitDeduction}

  @type calculation :: %{
          gross_cents: non_neg_integer(),
          tax_cents: non_neg_integer(),
          deductions_cents: non_neg_integer(),
          net_cents: non_neg_integer()
        }

  @doc """
  Calculates salary breakdown for `contract` with optional benefit deductions.

  Returns `{:ok, calculation}` or `{:error, reason}`.
  """
  @spec calculate(Contract.t(), [BenefitDeduction.t()]) ::
          {:ok, calculation()} | {:error, String.t()}
  def calculate(%Contract{} = contract, deductions \\ []) when is_list(deductions) do
    with {:ok, gross_cents} <- compute_gross(contract),
         {:ok, tax_cents} <- TaxTable.lookup(gross_cents, contract.tax_region),
         {:ok, deduction_total} <- sum_deductions(deductions) do
      net_cents = max(gross_cents - tax_cents - deduction_total, 0)

      {:ok,
       %{
         gross_cents: gross_cents,
         tax_cents: tax_cents,
         deductions_cents: deduction_total,
         net_cents: net_cents
       }}
    end
  end

  @doc """
  Formats a cents integer as a human-readable currency string.
  """
  @spec format_cents(integer(), String.t()) :: String.t()
  def format_cents(cents, currency_code)
      when is_integer(cents) and is_binary(currency_code) do
    whole = div(abs(cents), 100)
    fraction = rem(abs(cents), 100)
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{currency_code} #{whole}.#{String.pad_leading("#{fraction}", 2, "0")}"
  end

  defp compute_gross(%Contract{type: :full_time, monthly_salary_cents: salary})
       when is_integer(salary) and salary > 0 do
    {:ok, salary}
  end

  defp compute_gross(%Contract{type: :hourly, hourly_rate_cents: rate, hours_worked: hours})
       when is_integer(rate) and rate > 0 and is_number(hours) and hours >= 0 do
    {:ok, round(rate * hours)}
  end

  defp compute_gross(%Contract{type: :contractor, invoice_cents: invoice})
       when is_integer(invoice) and invoice > 0 do
    {:ok, invoice}
  end

  defp compute_gross(%Contract{type: type}) do
    {:error, "unsupported contract type: #{inspect(type)}"}
  end

  defp sum_deductions(deductions) do
    total =
      Enum.reduce_while(deductions, {:ok, 0}, fn deduction, {:ok, acc} ->
        case BenefitDeduction.amount_cents(deduction) do
          {:ok, cents} when is_integer(cents) and cents >= 0 ->
            {:cont, {:ok, acc + cents}}

          {:ok, _} ->
            {:halt, {:error, "deduction amount must be a non-negative integer"}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    total
  end
end
```
