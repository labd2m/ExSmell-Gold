```elixir
defmodule Compliance.KYCVerificationService do
  alias Compliance.{
    Repo,
    Applicant,
    DocumentParser,
    IdentityProvider,
    LivenessProvider,
    KYCRecord
  }

  require Logger

  @supported_document_types [:passport, :national_id, :driving_license]

  def run_kyc_verification(applicant_id, submission) do
    with {:ok, applicant} <- fetch_pending_applicant(applicant_id),
         {:ok, doc_data} <- DocumentParser.extract(submission.document_image, submission.document_type),
         {:ok, identity_result} <- IdentityProvider.verify(doc_data, applicant),
         {:ok, liveness_result} <- LivenessProvider.check(submission.selfie_image, doc_data),
         {:ok, kyc_record} <- persist_kyc_result(applicant, identity_result, liveness_result) do
      applicant
      |> Applicant.changeset(%{
        kyc_status: kyc_record.outcome,
        kyc_completed_at: DateTime.utc_now(),
        kyc_record_id: kyc_record.id
      })
      |> Repo.update()

      Logger.info(
        "KYC verification completed: applicant=#{applicant_id} " <>
          "outcome=#{kyc_record.outcome} record=#{kyc_record.id}"
      )

      {:ok, kyc_record}
    else
      {:error, :applicant_not_found} ->
        Logger.warning("Applicant #{applicant_id} not found for KYC")
        {:error, :applicant_not_found}

      {:error, :already_verified} ->
        Logger.info("Applicant #{applicant_id} is already KYC verified")
        {:error, :already_verified}

      {:error, :unsupported_document_type} ->
        Logger.warning("Unsupported document type: #{submission.document_type}")
        {:error, :document_type_not_accepted}

      {:error, :document_unreadable} ->
        Logger.warning("Document image unreadable for applicant #{applicant_id}")
        {:error, :document_processing_failed}

      {:error, :document_expired} ->
        Logger.warning("Expired document submitted for applicant #{applicant_id}")
        {:error, :document_expired}

      {:error, :identity_mismatch} ->
        Logger.warning("Identity mismatch for applicant #{applicant_id}")
        {:error, :identity_verification_failed}

      {:error, :identity_provider_unavailable} ->
        Logger.error("Identity provider unavailable during KYC for applicant #{applicant_id}")
        {:error, :external_service_unavailable}

      {:error, :liveness_check_failed} ->
        Logger.warning("Liveness check failed for applicant #{applicant_id}")
        {:error, :liveness_verification_failed}

      {:error, :liveness_provider_error} ->
        Logger.error("Liveness provider error for applicant #{applicant_id}")
        {:error, :external_service_unavailable}

      {:error, :db_error} ->
        Logger.error("KYC result persistence failed for applicant #{applicant_id}")
        {:error, :persistence_failed}
    end
  end

  defp fetch_pending_applicant(applicant_id) do
    case Repo.get(Applicant, applicant_id) do
      nil -> {:error, :applicant_not_found}
      %Applicant{kyc_status: :verified} -> {:error, :already_verified}
      applicant -> {:ok, applicant}
    end
  end

  defp persist_kyc_result(applicant, identity_result, liveness_result) do
    outcome = determine_outcome(identity_result, liveness_result)

    %KYCRecord{}
    |> KYCRecord.changeset(%{
      applicant_id: applicant.id,
      identity_score: identity_result.score,
      liveness_score: liveness_result.score,
      outcome: outcome,
      checks_passed: identity_result.checks ++ liveness_result.checks,
      verified_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, :db_error}
    end
  end

  defp determine_outcome(%{score: id_score}, %{score: lv_score})
       when id_score >= 0.85 and lv_score >= 0.80,
       do: :approved

  defp determine_outcome(_, _), do: :rejected
end
```
