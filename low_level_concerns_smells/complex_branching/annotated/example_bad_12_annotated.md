# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `process_verification_result/2`, inside the `case` that handles all response variants from `KycProviderClient.check/2`
- **Affected function(s):** `process_verification_result/2`
- **Short explanation:** `process_verification_result/2` funnels every possible KYC API outcome — verified, manual review required, document expired, document tampered, name mismatch, address mismatch, sanctions match, unsupported document type, and two transport errors — into one `case` block. Each branch triggers distinct state transitions and side-effects (compliance flags, manual review queues, notification dispatch, sanctions reporting). The high cyclomatic complexity makes this function very difficult to test per outcome, and any unhandled exception in a single branch (e.g., the sanctions-reporting call) prevents correct handling of all other branches.

```elixir
defmodule UserManagement.KycVerifier do
  @moduledoc """
  Orchestrates KYC document verification through a third-party compliance
  provider, managing state transitions, compliance flags, and review queues.
  """

  alias UserManagement.KycProviderClient
  alias UserManagement.UserStore
  alias UserManagement.ComplianceRegistry
  alias UserManagement.ManualReviewQueue
  alias UserManagement.SanctionsReporter
  alias Notifications.EmailDispatcher
  alias UserManagement.AuditLogger

  @supported_doc_types ~w(passport national_id drivers_license residence_permit)
  @review_sla_hours 48

  def verify_user_identity(user_id, document, opts \\ []) do
    operator_id = Keyword.get(opts, :operator_id, "system")
    priority    = Keyword.get(opts, :priority, :normal)

    with {:ok, user} <- UserStore.fetch(user_id),
         :ok <- assert_document_type_supported(document.type),
         {:ok, result} <- process_verification_result(user, document),
         :ok <- AuditLogger.log(:kyc_verification_attempted, user_id, %{
           result: result.status,
           operator: operator_id
         }) do
      {:ok, result}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `process_verification_result/2` handles
  # all possible outcomes of `KycProviderClient.check/2` in one `case` block.
  # Ten branches — verified, manual review, expired document, tampered document,
  # name mismatch, address mismatch, sanctions hit, unsupported type, timeout,
  # and generic error — each carry distinct side-effects and state transitions.
  # The cyclomatic complexity is very high; a developer adding a new branch
  # must understand all existing ones to avoid interference, and a runtime
  # exception in any one branch (e.g., `SanctionsReporter.file/2` failing)
  # will surface as a confusing error that does not identify which KYC
  # response variant was being handled.
  defp process_verification_result(user, document) do
    case KycProviderClient.check(user, document) do
      {:ok, %{result: "verified", score: score, verified_at: ts}} ->
        UserStore.mark_kyc_verified(user.id, %{score: score, verified_at: ts})
        EmailDispatcher.send_kyc_approved(user.email)
        {:ok, %{status: :verified, score: score}}

      {:ok, %{result: "manual_review_required", review_id: rid, reason: reason}} ->
        UserStore.set_kyc_status(user.id, :pending_review)
        ManualReviewQueue.enqueue(user.id, rid, reason, @review_sla_hours)
        EmailDispatcher.send_kyc_under_review(user.email, @review_sla_hours)
        {:ok, %{status: :pending_review, review_id: rid}}

      {:ok, %{result: "failed", reason: "document_expired", expired_at: exp}} ->
        UserStore.set_kyc_status(user.id, :failed)
        EmailDispatcher.send_kyc_rejected(user.email, :document_expired)
        {:error, {:document_expired, exp}}

      {:ok, %{result: "failed", reason: "document_tampered", confidence: conf}} ->
        ComplianceRegistry.flag(user.id, :document_tampering, %{confidence: conf})
        UserStore.set_kyc_status(user.id, :flagged)
        AuditLogger.log(:kyc_tamper_detected, user.id, %{confidence: conf})
        {:error, :document_tampered}

      {:ok, %{result: "failed", reason: "name_mismatch", provided: prov, detected: det}} ->
        UserStore.set_kyc_status(user.id, :failed)
        EmailDispatcher.send_kyc_rejected(user.email, :name_mismatch)
        {:error, {:name_mismatch, %{provided: prov, detected: det}}}

      {:ok, %{result: "failed", reason: "address_mismatch"}} ->
        UserStore.set_kyc_status(user.id, :failed)
        EmailDispatcher.send_kyc_rejected(user.email, :address_mismatch)
        {:error, :address_mismatch}

      {:ok, %{result: "failed", reason: "sanctions_match", sanctions_list: list, entry_id: eid}} ->
        ComplianceRegistry.flag(user.id, :sanctions_hit, %{list: list, entry_id: eid})
        SanctionsReporter.file(user.id, %{list: list, entry_id: eid})
        UserStore.set_kyc_status(user.id, :blocked)
        AuditLogger.log(:sanctions_match, user.id, %{list: list, entry_id: eid})
        {:error, {:sanctions_match, list}}

      {:ok, %{result: "failed", reason: "unsupported_document_type", type: dtype}} ->
        {:error, {:unsupported_document_type, dtype}}

      {:ok, %{result: "failed", reason: other}} ->
        AuditLogger.log(:kyc_unknown_failure, user.id, %{reason: other})
        {:error, {:kyc_failed, other}}

      {:error, %{code: "provider_timeout"}} ->
        {:error, :kyc_provider_timeout}

      {:error, reason} ->
        AuditLogger.log(:kyc_provider_error, user.id, %{reason: reason})
        {:error, :kyc_provider_error}
    end
  end
  # VALIDATION: SMELL END

  defp assert_document_type_supported(%{type: type}) when type in @supported_doc_types, do: :ok
  defp assert_document_type_supported(%{type: type}), do: {:error, {:unsupported_doc_type, type}}
end
```
