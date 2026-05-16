```elixir
defmodule Compliance.KYCVerifier do
  @moduledoc """
  Performs Know-Your-Customer identity verification:
  document parsing, watchlist screening, liveness check,
  risk scoring, and case creation.
  """

  alias Compliance.{
    DocumentParser,
    WatchlistEngine,
    LivenessChecker,
    RiskScorer,
    CaseRepository
  }

  require Logger

  @acceptable_risk_scores [:low, :medium]

  @doc """
  Verifies identity for `applicant_id` using the provided `submission`.

  `submission` must contain `:document_image` (base64), `:selfie_image` (base64),
  and `:declared_info` (map).

  Returns `{:ok, case_id}` or a descriptive compliance error.
  """
  @spec verify_identity(String.t(), map()) ::
          {:ok, String.t()}
          | {:error, :document_parse_failed}
          | {:error, :watchlist_hit, String.t()}
          | {:error, :liveness_failed}
          | {:error, :risk_too_high}
          | {:error, :case_creation_failed}
  def verify_identity(applicant_id, submission) do
    with {:ok, parsed_doc} <- DocumentParser.parse(submission.document_image, submission.declared_info),
         :ok               <- WatchlistEngine.screen(parsed_doc),
         :ok               <- LivenessChecker.verify(submission.selfie_image, parsed_doc.face_embedding),
         {:ok, risk}       <- RiskScorer.score(applicant_id, parsed_doc),
         {:ok, kyc_case}   <- CaseRepository.create(%{
                                applicant_id:  applicant_id,
                                document_type: parsed_doc.type,
                                document_no:   parsed_doc.number,
                                risk_level:    risk.level,
                                verified_at:   DateTime.utc_now()
                              }) do
      Logger.info("KYC case #{kyc_case.id} created for applicant #{applicant_id}, risk=#{risk.level}")
      {:ok, kyc_case.id}
    else
      {:error, :parse, detail} ->
        Logger.warn("Document parse failed for #{applicant_id}: #{inspect(detail)}")
        {:error, :document_parse_failed}

      {:hit, list_name} ->
        Logger.warn("Watchlist hit for #{applicant_id} on list: #{list_name}")
        {:error, :watchlist_hit, list_name}

      {:error, :liveness} ->
        Logger.warn("Liveness check failed for #{applicant_id}")
        {:error, :liveness_failed}

      {:error, :risk, level} when level not in @acceptable_risk_scores ->
        Logger.warn("Risk level #{level} exceeds threshold for #{applicant_id}")
        {:error, :risk_too_high}

      {:error, :case, reason} ->
        Logger.error("KYC case creation failed: #{inspect(reason)}")
        {:error, :case_creation_failed}
    end
  end
end
```
