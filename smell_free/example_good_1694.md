```elixir
defmodule Payroll.PayslipCalculator do
  @moduledoc """
  Computes employee payslips from a gross salary and a set of applicable deductions.
  Supports progressive tax brackets, pension contributions, and optional benefit deductions.
  """

  @type bracket :: %{up_to: number() | :infinity, rate: float()}
  @type deduction :: %{label: String.t(), amount_cents: non_neg_integer()}
  @type payslip :: %{
    gross_cents: pos_integer(),
    tax_cents: non_neg_integer(),
    deductions: [deduction()],
    net_cents: non_neg_integer()
  }

  @tax_brackets [
    %{up_to: 1_500_000, rate: 0.15},
    %{up_to: 4_000_000, rate: 0.225},
    %{up_to: :infinity, rate: 0.275}
  ]

  @spec compute(pos_integer(), [deduction()]) :: {:ok, payslip()} | {:error, String.t()}
  def compute(gross_cents, deductions)
      when is_integer(gross_cents) and gross_cents > 0 and is_list(deductions) do
    with :ok <- validate_deductions(deductions) do
      tax_cents = calculate_progressive_tax(gross_cents, @tax_brackets)
      deduction_total = sum_deductions(deductions)
      net_cents = max(gross_cents - tax_cents - deduction_total, 0)

      {:ok, %{gross_cents: gross_cents, tax_cents: tax_cents, deductions: deductions, net_cents: net_cents}}
    end
  end

  @spec effective_tax_rate(payslip()) :: float()
  def effective_tax_rate(%{gross_cents: gross, tax_cents: tax}) when gross > 0 do
    Float.round(tax / gross * 100, 2)
  end

  @spec format_payslip(payslip()) :: String.t()
  def format_payslip(%{gross_cents: gross, tax_cents: tax, deductions: deductions, net_cents: net}) do
    deduction_lines = Enum.map_join(deductions, "\n", fn d ->
      "  #{d.label}: -#{format_currency(d.amount_cents)}"
    end)

    """
    Gross Pay:    #{format_currency(gross)}
    Tax:          -#{format_currency(tax)}
    #{deduction_lines}
    Net Pay:      #{format_currency(net)}
    """
  end

  @spec calculate_progressive_tax(pos_integer(), [bracket()]) :: non_neg_integer()
  defp calculate_progressive_tax(gross_cents, brackets) do
    {tax, _} =
      Enum.reduce(brackets, {0, gross_cents}, fn bracket, {acc_tax, remaining} ->
        apply_bracket(bracket, acc_tax, remaining)
      end)

    tax
  end

  @spec apply_bracket(bracket(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp apply_bracket(%{up_to: :infinity, rate: rate}, acc_tax, remaining) do
    {acc_tax + round(remaining * rate), 0}
  end

  defp apply_bracket(%{up_to: up_to, rate: rate}, acc_tax, remaining) do
    taxable = min(remaining, up_to)
    {acc_tax + round(taxable * rate), remaining - taxable}
  end

  @spec sum_deductions([deduction()]) :: non_neg_integer()
  defp sum_deductions(deductions) do
    Enum.reduce(deductions, 0, &(&1.amount_cents + &2))
  end

  @spec validate_deductions([deduction()]) :: :ok | {:error, String.t()}
  defp validate_deductions(deductions) do
    invalid = Enum.find(deductions, &invalid_deduction?/1)

    if invalid do
      {:error, "Invalid deduction: #{inspect(invalid)}"}
    else
      :ok
    end
  end

  @spec invalid_deduction?(map()) :: boolean()
  defp invalid_deduction?(%{label: l, amount_cents: a})
       when is_binary(l) and l != "" and is_integer(a) and a >= 0,
       do: false

  defp invalid_deduction?(_), do: true

  @spec format_currency(non_neg_integer()) :: String.t()
  defp format_currency(cents) do
    "$#{div(cents, 100)}.#{String.pad_leading("#{rem(cents, 100)}", 2, "0")}"
  end
end
```
