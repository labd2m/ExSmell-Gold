# Annotated Example 25

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ComplianceChecker.evaluate/1`
- **Affected function(s):** `evaluate/1`
- **Short explanation:** `evaluate/1` handles GDPR data access request validation, AML transaction screening, and export control compliance checks — three completely unrelated regulatory domains — under one multi-clause function. Each clause enforces different legal frameworks with entirely distinct data sources and outcomes.

```elixir
defmodule ComplianceChecker do
  @moduledoc """
  Regulatory compliance evaluation module.
  Handles GDPR data subject requests, AML transaction screening,
  and trade/export control checks for cross-border operations.
  """

  alias ComplianceChecker.{
    GdprAccessRequest,
    AmlScreeningRequest,
    ExportControlRequest,
    DataSubjectRegistry,
    SanctionsDatabase,
    ExportControlDatabase,
    ComplianceLog,
    LegalTeamNotifier,
    RiskScorer
  }

  require Logger

  @doc """
  Evaluate a compliance request against the applicable regulatory framework.

  Accepts a `%GdprAccessRequest{}`, `%AmlScreeningRequest{}`, or
  `%ExportControlRequest{}` and returns a compliance verdict.

  ## Examples

      iex> ComplianceChecker.evaluate(%GdprAccessRequest{subject_email: "user@example.com", requested_by: "user@example.com"})
      {:ok, %{verdict: :approved, data_package_url: "https://..."}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because GDPR data subject access rights,
  # AML/CFT transaction screening, and export control classification are
  # governed by entirely different legal frameworks (EU GDPR, FATF/FinCEN,
  # and EAR/ITAR respectively), with different data sources, timelines,
  # and regulatory obligations. Grouping them in one `evaluate/1` conflates
  # unrelated compliance domains.

  def evaluate(%GdprAccessRequest{
        subject_email: subject_email,
        requested_by: requester_email,
        request_id: request_id,
        received_at: received_at
      }) do
    deadline = DateTime.add(received_at, 30 * 24 * 3600, :second)

    with :ok <- validate_requester_identity(subject_email, requester_email),
         {:ok, subject} <- DataSubjectRegistry.find_by_email(subject_email),
         {:ok, data_package} <- DataSubjectRegistry.compile_data_export(subject.id),
         {:ok, package_url} <- DataSubjectRegistry.store_export(request_id, data_package),
         :ok <-
           ComplianceLog.record(%{
             type: :gdpr_access,
             request_id: request_id,
             subject_id: subject.id,
             evaluated_at: DateTime.utc_now(),
             deadline: deadline,
             verdict: :approved
           }) do
      Logger.info("GDPR access request #{request_id} fulfilled for #{subject_email}")
      {:ok, %{verdict: :approved, data_package_url: package_url, deadline: deadline}}
    end
  end

  # evaluate AML screening for a financial transaction
  def evaluate(%AmlScreeningRequest{
        transaction_id: txn_id,
        sender: sender,
        receiver: receiver,
        amount: amount,
        currency: currency,
        jurisdiction: jurisdiction
      }) do
    with {:ok, sender_result} <- SanctionsDatabase.screen_entity(sender),
         {:ok, receiver_result} <- SanctionsDatabase.screen_entity(receiver),
         risk_score = RiskScorer.compute_aml_risk(sender_result, receiver_result, amount, jurisdiction),
         verdict = aml_verdict(risk_score),
         :ok <-
           ComplianceLog.record(%{
             type: :aml_screening,
             transaction_id: txn_id,
             sender: sender,
             receiver: receiver,
             amount: amount,
             currency: currency,
             risk_score: risk_score,
             verdict: verdict,
             evaluated_at: DateTime.utc_now()
           }),
         :ok <- maybe_escalate_aml(verdict, txn_id, risk_score) do
      Logger.info("AML screening for txn #{txn_id}: #{verdict} (score=#{risk_score})")
      {:ok, %{verdict: verdict, risk_score: risk_score}}
    end
  end

  # evaluate export control classification for a cross-border shipment
  def evaluate(%ExportControlRequest{
        shipment_id: shipment_id,
        items: items,
        destination_country: country,
        end_user: end_user
      }) do
    with {:ok, classifications} <- ExportControlDatabase.classify_items(items),
         {:ok, country_status} <- ExportControlDatabase.check_country(country),
         {:ok, end_user_status} <- ExportControlDatabase.check_end_user(end_user),
         verdict = export_verdict(classifications, country_status, end_user_status),
         :ok <-
           ComplianceLog.record(%{
             type: :export_control,
             shipment_id: shipment_id,
             destination: country,
             end_user: end_user,
             classifications: classifications,
             verdict: verdict,
             evaluated_at: DateTime.utc_now()
           }),
         :ok <- maybe_alert_export_blocked(verdict, shipment_id, country) do
      Logger.info("Export control for shipment #{shipment_id} to #{country}: #{verdict}")
      {:ok, %{verdict: verdict, classifications: classifications}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_requester_identity(subject_email, requester_email)
       when subject_email == requester_email,
       do: :ok

  defp validate_requester_identity(_, _), do: {:error, :requester_not_subject}

  defp aml_verdict(score) when score >= 80, do: :blocked
  defp aml_verdict(score) when score >= 50, do: :review_required
  defp aml_verdict(_), do: :cleared

  defp export_verdict(_classifications, :embargoed, _end_user), do: :blocked
  defp export_verdict(_classifications, _country, :denied_party), do: :blocked
  defp export_verdict(classifications, _country, _end_user) do
    if Enum.any?(classifications, &(&1.control_list == :ear99)) do
      :license_required
    else
      :approved
    end
  end

  defp maybe_escalate_aml(:blocked, txn_id, score) do
    LegalTeamNotifier.alert_aml_block(txn_id, score)
  end

  defp maybe_escalate_aml(_, _, _), do: :ok

  defp maybe_alert_export_blocked(:blocked, shipment_id, country) do
    LegalTeamNotifier.alert_export_block(shipment_id, country)
  end

  defp maybe_alert_export_blocked(_, _, _), do: :ok
end
```
