```elixir
defmodule MyApp.Compliance.KYCClient do
  @moduledoc """
  Client for the external KYC (Know Your Customer) identity verification provider.
  Handles document submission, status polling, and verification outcome processing.
  """

  require Logger

  alias MyApp.Compliance.{VerificationRecord, SanctionsLog, ComplianceAlerter}
  alias MyApp.Accounts.{UserProfile, OnboardingWorkflow}

  @api_base "https://api.kycprovider.io/v2"
  @http_timeout_ms 15_000

  @spec submit_verification(String.t(), map()) ::
          {:ok, map()} | {:error, atom() | map()}
  def submit_verification(user_id, verification_payload) do
    headers = build_headers()
    body = Jason.encode!(verification_payload)
    url = "#{@api_base}/verifications"

    Logger.info("Submitting KYC verification for user=#{user_id}")

    case HTTPoison.post(url, body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)

        case parsed["decision"] do
          "APPROVED" ->
            VerificationRecord.save(user_id, :approved, parsed)
            OnboardingWorkflow.advance(user_id, :kyc_approved)
            Logger.info("KYC approved for user=#{user_id}")
            {:ok, %{status: :approved, reference: parsed["reference_id"]}}

          "MANUAL_REVIEW" ->
            VerificationRecord.save(user_id, :manual_review, parsed)
            ComplianceAlerter.notify_review_queue(user_id, parsed["reference_id"], parsed["review_reason"])
            Logger.info("KYC requires manual review for user=#{user_id} reason=#{parsed["review_reason"]}")
            {:ok, %{status: :pending_review, reference: parsed["reference_id"]}}

          "REJECTED" ->
            rejection_code = parsed["rejection_code"]

            cond do
              rejection_code == "DOCUMENT_EXPIRED" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                OnboardingWorkflow.request_document_resubmission(user_id, :document_expired)
                Logger.warning("KYC rejected: document expired user=#{user_id}")
                {:error, :document_expired}

              rejection_code == "DOCUMENT_UNREADABLE" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                OnboardingWorkflow.request_document_resubmission(user_id, :unreadable)
                Logger.warning("KYC rejected: document unreadable user=#{user_id}")
                {:error, :document_unreadable}

              rejection_code == "DOCUMENT_TYPE_NOT_ACCEPTED" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                OnboardingWorkflow.request_document_resubmission(user_id, :wrong_doc_type)
                Logger.warning("KYC rejected: document type not accepted user=#{user_id}")
                {:error, :document_type_rejected}

              rejection_code == "IDENTITY_MISMATCH" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                UserProfile.flag(user_id, :identity_mismatch)
                ComplianceAlerter.notify_identity_mismatch(user_id)
                Logger.warning("KYC rejected: identity mismatch user=#{user_id}")
                {:error, :identity_mismatch}

              rejection_code == "SANCTIONS_HIT" ->
                VerificationRecord.save(user_id, :rejected_sanctions, parsed)
                SanctionsLog.record(user_id, parsed["sanctions_detail"])
                UserProfile.block(user_id, :sanctions)
                ComplianceAlerter.notify_sanctions_hit(user_id, parsed["sanctions_detail"])
                Logger.error("KYC rejected: sanctions hit user=#{user_id}")
                {:error, :sanctions_hit}

              rejection_code == "PEP_FLAG" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                ComplianceAlerter.notify_pep_flag(user_id)
                Logger.warning("KYC rejected: PEP flag user=#{user_id}")
                {:error, :pep_flagged}

              rejection_code == "UNDERAGE" ->
                VerificationRecord.save(user_id, :rejected, parsed)
                OnboardingWorkflow.terminate(user_id, :underage)
                Logger.warning("KYC rejected: user underage user=#{user_id}")
                {:error, :underage}

              true ->
                VerificationRecord.save(user_id, :rejected, parsed)
                Logger.warning("KYC rejected: unknown code=#{rejection_code} user=#{user_id}")
                {:error, {:unknown_rejection, rejection_code}}
            end

          other ->
            Logger.error("KYC unexpected decision=#{other} user=#{user_id}")
            {:error, {:unexpected_decision, other}}
        end

      {:ok, %HTTPoison.Response{status_code: 400, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.error("KYC bad request: #{inspect(parsed["errors"])} user=#{user_id}")
        {:error, {:bad_request, parsed["errors"]}}

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("KYC provider authentication failed")
        {:error, :auth_failed}

      {:ok, %HTTPoison.Response{status_code: 409, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.info("KYC duplicate submission for user=#{user_id} existing=#{parsed["existing_reference"]}")
        {:error, {:duplicate_submission, parsed["existing_reference"]}}

      {:ok, %HTTPoison.Response{status_code: 422}} ->
        Logger.warning("KYC session expired user=#{user_id}")
        {:error, :session_expired}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warning("KYC provider rate limited")
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("KYC provider server error status=#{status}")
        {:error, :provider_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("KYC provider timeout user=#{user_id}")
        {:error, :provider_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("KYC network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @spec poll_status(String.t()) :: {:ok, map()} | {:error, atom()}
  def poll_status(reference_id) do
    headers = build_headers()
    url = "#{@api_base}/verifications/#{reference_id}"

    case HTTPoison.get(url, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, Jason.decode!(body)}
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, :not_found}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  defp build_headers do
    api_key = Application.fetch_env!(:my_app, :kyc_api_key)
    [{"Authorization", "ApiKey #{api_key}"}, {"Content-Type", "application/json"}]
  end
end
```
