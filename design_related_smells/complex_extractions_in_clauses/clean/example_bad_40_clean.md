```elixir
defmodule Tax.FilingProcessor do
  @moduledoc """
  Processes individual and business tax filings. Calculates liability,
  applies eligible deductions, determines refund or balance-due amounts,
  and submits to the revenue authority gateway.
  """

  require Logger

  alias Tax.{
    LiabilityCalculator,
    DeductionEngine,
    RevenueGateway,
    FilingRepo,
    AuditLog,
    TaxpayerMailer,
    ComplianceChecker
  }

  @standard_deduction_single 13_850
  @high_income_threshold 400_000
  @business_income_threshold 1_000_000

  # `deductions`, and `withholdings` are extracted in the head of every clause
  # but are only consumed inside the bodies — they do not drive clause selection
  # or guard evaluation. Only `filing_type` determines which clause fires, and
  # `gross_income` is used in the guards. Across four clauses with seven
  # bindings each, identifying this two-field dispatch mechanism requires
  # inspecting every binding in every clause head.
  def process(%Tax.Filing{
        filing_id: filing_id,
        taxpayer_id: taxpayer_id,
        tax_year: tax_year,
        deductions: deductions,
        withholdings: withholdings,
        filing_type: :individual,
        gross_income: gross_income
      })
      when gross_income <= @high_income_threshold do
    Logger.info(
      "[FilingProcessor] Processing individual filing #{filing_id} for taxpayer #{taxpayer_id}, " <>
        "year #{tax_year}, gross income: #{gross_income}"
    )

    effective_deductions =
      max(deductions, @standard_deduction_single)

    taxable_income = max(gross_income - effective_deductions, 0)

    with {:ok, liability} <- LiabilityCalculator.individual(taxable_income, tax_year),
         refund_or_due = withholdings - liability,
         {:ok, submission_id} <- RevenueGateway.submit_individual(filing_id, liability, refund_or_due),
         {:ok, _} <- FilingRepo.update_status(filing_id, :submitted, %{
                       submission_id: submission_id,
                       liability: liability,
                       refund_or_due: refund_or_due
                     }),
         :ok <- TaxpayerMailer.send_filing_confirmation(taxpayer_id, filing_id, refund_or_due),
         :ok <- AuditLog.write(:filing_submitted, taxpayer_id, %{
                  filing_id: filing_id,
                  tax_year: tax_year,
                  liability: liability,
                  refund_or_due: refund_or_due
                }) do
      {:ok, :submitted, submission_id}
    else
      {:error, :gateway_unavailable} ->
        Logger.warning("[FilingProcessor] Revenue gateway unavailable for #{filing_id}. Queuing retry.")
        Tax.RetryQueue.enqueue(filing_id)
        {:error, :gateway_unavailable}

      {:error, reason} ->
        Logger.error("[FilingProcessor] Filing #{filing_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process(%Tax.Filing{
        filing_id: filing_id,
        taxpayer_id: taxpayer_id,
        tax_year: tax_year,
        deductions: deductions,
        withholdings: withholdings,
        filing_type: :individual,
        gross_income: gross_income
      })
      when gross_income > @high_income_threshold do
    Logger.info(
      "[FilingProcessor] High-income individual filing #{filing_id}: #{gross_income}"
    )

    with :ok <- ComplianceChecker.validate_high_income(taxpayer_id, gross_income, deductions),
         taxable_income = max(gross_income - deductions, 0),
         {:ok, liability} <- LiabilityCalculator.individual_high_income(taxable_income, tax_year),
         refund_or_due = withholdings - liability,
         {:ok, submission_id} <- RevenueGateway.submit_individual(filing_id, liability, refund_or_due),
         {:ok, _} <- FilingRepo.update_status(filing_id, :submitted_reviewed, %{
                       submission_id: submission_id,
                       liability: liability
                     }),
         :ok <- AuditLog.write(:high_income_filing_submitted, taxpayer_id, %{
                  filing_id: filing_id,
                  tax_year: tax_year,
                  gross_income: gross_income,
                  liability: liability
                }) do
      {:ok, :submitted, submission_id}
    else
      {:error, :compliance_hold} ->
        Logger.warning("[FilingProcessor] Compliance hold on high-income filing #{filing_id}")
        FilingRepo.update_status(filing_id, :compliance_hold, %{})
        {:error, :compliance_hold}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def process(%Tax.Filing{
        filing_id: filing_id,
        taxpayer_id: taxpayer_id,
        tax_year: tax_year,
        deductions: deductions,
        withholdings: withholdings,
        filing_type: :business,
        gross_income: gross_income
      })
      when gross_income < @business_income_threshold do
    Logger.info("[FilingProcessor] Processing small-business filing #{filing_id}")

    taxable_income = max(gross_income - deductions, 0)

    with {:ok, liability} <- LiabilityCalculator.business(taxable_income, :small, tax_year),
         refund_or_due = withholdings - liability,
         {:ok, submission_id} <- RevenueGateway.submit_business(filing_id, liability, refund_or_due),
         {:ok, _} <- FilingRepo.update_status(filing_id, :submitted, %{submission_id: submission_id}),
         :ok <- TaxpayerMailer.send_filing_confirmation(taxpayer_id, filing_id, refund_or_due),
         :ok <- AuditLog.write(:business_filing_submitted, taxpayer_id, %{
                  filing_id: filing_id,
                  tax_year: tax_year,
                  gross_income: gross_income,
                  liability: liability
                }) do
      {:ok, :submitted, submission_id}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def process(%Tax.Filing{
        filing_id: filing_id,
        taxpayer_id: taxpayer_id,
        tax_year: tax_year,
        deductions: deductions,
        withholdings: withholdings,
        filing_type: :business,
        gross_income: gross_income
      })
      when gross_income >= @business_income_threshold do
    Logger.info("[FilingProcessor] Processing large-business filing #{filing_id}: #{gross_income}")

    taxable_income = max(gross_income - deductions, 0)

    with :ok <- ComplianceChecker.validate_large_business(taxpayer_id, gross_income, deductions),
         {:ok, liability} <- LiabilityCalculator.business(taxable_income, :large, tax_year),
         refund_or_due = withholdings - liability,
         {:ok, submission_id} <- RevenueGateway.submit_business(filing_id, liability, refund_or_due),
         {:ok, _} <- FilingRepo.update_status(filing_id, :submitted_auditable, %{
                       submission_id: submission_id,
                       liability: liability
                     }),
         :ok <- AuditLog.write(:large_business_filing_submitted, taxpayer_id, %{
                  filing_id: filing_id,
                  tax_year: tax_year,
                  gross_income: gross_income,
                  deductions: deductions,
                  withholdings: withholdings
                }) do
      {:ok, :submitted, submission_id}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def process(%Tax.Filing{filing_id: id, filing_type: unknown}) do
    Logger.error("[FilingProcessor] Unsupported filing type '#{unknown}' on #{id}")
    {:error, :unsupported_filing_type}
  end
end
```
