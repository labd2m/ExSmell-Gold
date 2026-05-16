# Annotated Example 37

- **Smell name:** Complex Branching
- **Expected smell location:** `submit_report/2` function, the `case` expression over the tax authority API response
- **Affected function(s):** `submit_report/2`
- **Short explanation:** A single function is responsible for interpreting every possible response variant from a tax reporting API — successful filing, accepted with warnings, validation errors for multiple distinct field sets, duplicate submissions, rejected filings, and infrastructure failures — all inside one `case`, making the function excessively complex and fragile.

```elixir
defmodule Reporting.TaxFilingService do
  @moduledoc """
  Submits periodic tax reports to the national tax authority's API (TaxGov).
  Covers VAT, corporate income tax, and payroll tax declarations.
  """

  require Logger

  alias Reporting.Repo
  alias Reporting.Schema.{TaxFiling, Company, FilingAuditLog}
  alias Reporting.TaxGov.Client
  alias Reporting.Alerts

  @filing_types [:vat_quarterly, :corporate_annual, :payroll_monthly]
  @max_filing_size_kb 5_120

  def file(company_id, filing_type, period, report_data)
      when filing_type in @filing_types do
    with {:ok, company} <- fetch_company(company_id),
         :ok <- validate_period(period, filing_type),
         :ok <- check_filing_size(report_data),
         :ok <- check_duplicate(company_id, filing_type, period),
         {:ok, signed} <- sign_report(company, report_data) do
      submit_report(company, Client.post("/declarations/#{filing_type}", signed))
    end
  end

  defp fetch_company(id) do
    case Repo.get(Company, id) do
      nil -> {:error, :company_not_found}
      c -> {:ok, c}
    end
  end

  defp validate_period(_period, _type), do: :ok

  defp check_filing_size(data) do
    size = data |> Jason.encode!() |> byte_size() |> div(1024)
    if size > @max_filing_size_kb, do: {:error, :report_too_large}, else: :ok
  end

  defp check_duplicate(company_id, type, period) do
    case Repo.get_by(TaxFiling, company_id: company_id, filing_type: type, period: period) do
      nil -> :ok
      _ -> {:error, :duplicate_filing}
    end
  end

  defp sign_report(company, data) do
    Client.sign(%{tax_id: company.tax_id, data: data})
  end

  # VALIDATION: SMELL START - Complex Branching
  # VALIDATION: This is a smell because all TaxGov response variants from a
  # single declarations endpoint — successful acceptance, acceptance with warnings,
  # multiple categories of validation errors, duplicate detection, outright
  # rejection, and infrastructure issues — are all handled by one function
  # through a large case with many arms, producing high cyclomatic complexity.
  defp submit_report(company, tax_response) do
    case tax_response do
      {:ok, %{status: 200, body: %{"declaration_id" => did, "status" => "accepted", "receipt" => receipt}}} ->
        Logger.info("Tax filing #{did} accepted for company #{company.id}")

        {:ok, filing} =
          Repo.insert(%TaxFiling{
            company_id: company.id,
            declaration_id: did,
            receipt: receipt,
            status: :accepted
          })

        Repo.insert(%FilingAuditLog{tax_filing_id: filing.id, event: :accepted})
        {:ok, filing}

      {:ok, %{status: 200, body: %{"declaration_id" => did, "status" => "accepted_with_warnings", "warnings" => warnings}}} ->
        Logger.warning("Filing #{did} accepted with warnings for company #{company.id}: #{inspect(warnings)}")

        {:ok, filing} =
          Repo.insert(%TaxFiling{
            company_id: company.id,
            declaration_id: did,
            status: :accepted_with_warnings,
            warnings: warnings
          })

        Alerts.notify_filing_warnings(company, filing, warnings)
        {:ok, filing}

      {:ok, %{status: 422, body: %{"error" => "validation_failed", "fields" => fields}}} ->
        Logger.warning("Filing validation failed for company #{company.id}, fields: #{inspect(fields)}")
        {:error, {:validation_failed, fields}}

      {:ok, %{status: 422, body: %{"error" => "invalid_tax_period"}}} ->
        Logger.warning("Invalid tax period in filing for company #{company.id}")
        {:error, :invalid_tax_period}

      {:ok, %{status: 422, body: %{"error" => "invalid_tax_id"}}} ->
        Logger.error("Invalid tax ID for company #{company.id}")
        {:error, :invalid_tax_id}

      {:ok, %{status: 422, body: %{"error" => "schema_version_unsupported", "supported" => supported}}} ->
        Logger.error("Schema version unsupported for company #{company.id}, supported: #{supported}")
        {:error, {:schema_version_unsupported, supported}}

      {:ok, %{status: 409, body: %{"error" => "declaration_already_submitted", "original_id" => orig_id}}} ->
        Logger.warning("Duplicate filing detected for company #{company.id}, original #{orig_id}")
        {:error, {:already_submitted, orig_id}}

      {:ok, %{status: 403, body: %{"error" => "filing_window_closed", "next_window" => next}}} ->
        Logger.warning("Filing window closed for company #{company.id}, next: #{next}")
        {:error, {:filing_window_closed, next}}

      {:ok, %{status: 400, body: %{"error" => "digital_signature_invalid"}}} ->
        Logger.error("Invalid digital signature for company #{company.id}")
        {:error, :invalid_signature}

      {:ok, %{status: 500, body: %{"error" => "rejected", "reason" => reason}}} ->
        Logger.error("Filing rejected by TaxGov for company #{company.id}: #{reason}")
        Alerts.notify_filing_rejection(company, reason)
        {:error, {:rejected, reason}}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by TaxGov for company #{company.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("TaxGov service unavailable for company #{company.id}")
        {:error, :tax_authority_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected TaxGov response #{status} for company #{company.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("TaxGov timeout for company #{company.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("TaxGov connection error for company #{company.id}: #{inspect(reason)}")
        {:error, {:authority_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  def filing_history(company_id) do
    TaxFiling
    |> TaxFiling.for_company(company_id)
    |> Repo.all()
  end
end
```
