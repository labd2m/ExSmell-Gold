```elixir
defmodule TaxEngine do
  @moduledoc """
  Tax computation engine for the financial platform.
  Handles VAT/sales tax for e-commerce, payroll tax withholding,
  and capital gains tax estimation across multiple jurisdictions.
  """

  alias TaxEngine.{
    VatCalculationRequest,
    PayrollWithholdingRequest,
    CapitalGainsRequest,
    TaxRateStore,
    JurisdictionResolver,
    TaxBracketTable,
    ExemptionRegistry,
    TaxRecordStore
  }

  require Logger

  @doc """
  Compute a tax liability for the given request.

  Accepts a `%VatCalculationRequest{}`, `%PayrollWithholdingRequest{}`, or
  `%CapitalGainsRequest{}` and returns the applicable tax amounts.

  ## Examples

      iex> TaxEngine.compute(%VatCalculationRequest{order_id: "ord_1", items: [...], ship_to: "DE"})
      {:ok, %{vat_amount: 19_00, rate: 0.19, jurisdiction: "DE"}}

  """
  def compute(%VatCalculationRequest{
        order_id: order_id,
        items: items,
        ship_to: country_code,
        customer_vat_id: vat_id
      }) do
    with {:ok, jurisdiction} <- JurisdictionResolver.resolve_vat(country_code),
         :ok <- maybe_validate_reverse_charge(vat_id, jurisdiction),
         {:ok, rate} <- TaxRateStore.get_vat_rate(jurisdiction),
         taxable_items = Enum.reject(items, &exempt_from_vat?(&1, jurisdiction)),
         taxable_subtotal = Enum.sum(Enum.map(taxable_items, & &1.subtotal)),
         vat_amount = round(taxable_subtotal * rate),
         {:ok, _} <-
           TaxRecordStore.record(%{
             type: :vat,
             reference_id: order_id,
             jurisdiction: jurisdiction,
             taxable_amount: taxable_subtotal,
             tax_amount: vat_amount,
             rate: rate,
             computed_at: DateTime.utc_now()
           }) do
      Logger.debug("VAT computed for order #{order_id}: #{vat_amount} (#{country_code} rate=#{rate})")
      {:ok, %{vat_amount: vat_amount, rate: rate, jurisdiction: jurisdiction}}
    end
  end

  # compute payroll tax withholding for an employee pay period
  def compute(%PayrollWithholdingRequest{
        employee_id: employee_id,
        gross_pay: gross_pay,
        pay_period: pay_period,
        filing_status: filing_status,
        jurisdiction: jurisdiction,
        pre_tax_deductions: deductions
      }) do
    taxable_income = gross_pay - Enum.sum(Enum.map(deductions, & &1.amount))

    with {:ok, brackets} <- TaxBracketTable.fetch(:income, jurisdiction, filing_status, pay_period),
         {:ok, exemptions} <- ExemptionRegistry.get_employee_exemptions(employee_id),
         exemption_value = compute_exemption_value(exemptions, pay_period),
         adjusted_income = max(0, taxable_income - exemption_value),
         federal_withholding = apply_tax_brackets(adjusted_income, brackets.federal),
         state_withholding = apply_tax_brackets(adjusted_income, brackets.state),
         fica = compute_fica(gross_pay),
         total_withholding = federal_withholding + state_withholding + fica,
         {:ok, _} <-
           TaxRecordStore.record(%{
             type: :payroll_withholding,
             reference_id: "#{employee_id}_#{pay_period}",
             jurisdiction: jurisdiction,
             gross_pay: gross_pay,
             taxable_income: adjusted_income,
             federal: federal_withholding,
             state: state_withholding,
             fica: fica,
             total: total_withholding,
             computed_at: DateTime.utc_now()
           }) do
      Logger.debug("Payroll withholding for #{employee_id} period #{pay_period}: #{total_withholding}")
      {:ok, %{federal: federal_withholding, state: state_withholding, fica: fica, total: total_withholding}}
    end
  end

  # compute estimated capital gains tax on investment disposal
  def compute(%CapitalGainsRequest{
        investor_id: investor_id,
        asset_id: asset_id,
        acquisition_date: acq_date,
        disposal_date: disp_date,
        acquisition_cost: cost,
        disposal_proceeds: proceeds,
        jurisdiction: jurisdiction
      }) do
    holding_days = Date.diff(disp_date, acq_date)
    holding_type = if holding_days >= 365, do: :long_term, else: :short_term
    raw_gain = proceeds - cost

    with {:ok, rate} <- TaxRateStore.get_cgt_rate(jurisdiction, holding_type),
         {:ok, allowance} <- TaxRateStore.get_annual_cgt_allowance(jurisdiction),
         {:ok, used_allowance} <- TaxRecordStore.get_used_cgt_allowance(investor_id, disp_date.year),
         remaining_allowance = max(0, allowance - used_allowance),
         taxable_gain = max(0, raw_gain - remaining_allowance),
         estimated_tax = round(taxable_gain * rate),
         {:ok, _} <-
           TaxRecordStore.record(%{
             type: :capital_gains,
             reference_id: "#{investor_id}_#{asset_id}",
             jurisdiction: jurisdiction,
             holding_type: holding_type,
             gross_gain: raw_gain,
             taxable_gain: taxable_gain,
             tax_amount: estimated_tax,
             rate: rate,
             computed_at: DateTime.utc_now()
           }) do
      Logger.debug("CGT for investor #{investor_id} on #{asset_id}: #{estimated_tax} (#{holding_type})")
      {:ok, %{taxable_gain: taxable_gain, estimated_tax: estimated_tax, holding_type: holding_type, rate: rate}}
    end
  end

  defp exempt_from_vat?(item, jurisdiction) do
    ExemptionRegistry.vat_exempt?(item.category, jurisdiction)
  end

  defp maybe_validate_reverse_charge(nil, _jurisdiction), do: :ok

  defp maybe_validate_reverse_charge(vat_id, jurisdiction) do
    case JurisdictionResolver.validate_vat_id(vat_id, jurisdiction) do
      {:ok, :valid} -> :ok
      _ -> {:error, :invalid_vat_id}
    end
  end

  defp compute_exemption_value(exemptions, pay_period) do
    annual_value = Enum.sum(Enum.map(exemptions, & &1.annual_amount))
    periods = pay_period_count(pay_period)
    div(annual_value, periods)
  end

  defp pay_period_count(:weekly), do: 52
  defp pay_period_count(:biweekly), do: 26
  defp pay_period_count(:monthly), do: 12
  defp pay_period_count(_), do: 26

  defp apply_tax_brackets(income, brackets) do
    Enum.reduce(brackets, {income, 0}, fn bracket, {remaining, acc} ->
      if remaining <= 0 do
        {0, acc}
      else
        taxable_in_bracket = min(remaining, bracket.ceiling - bracket.floor)
        tax = round(taxable_in_bracket * bracket.rate)
        {remaining - taxable_in_bracket, acc + tax}
      end
    end)
    |> elem(1)
  end

  defp compute_fica(gross_pay) do
    ss = min(gross_pay, 16_040_000) |> Kernel.*(0.062) |> round()
    medicare = round(gross_pay * 0.0145)
    ss + medicare
  end
end
```
