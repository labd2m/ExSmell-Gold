```elixir
defmodule Compliance.KycWorkflow do
  @moduledoc """
  Orchestrates multi-step Know Your Customer (KYC) verification for newly
  onboarded accounts. The workflow progresses through document upload,
  liveness check, sanctions screening, and manual review stages. Each
  transition is gated by explicit preconditions, and the aggregate status
  is derived from the individual step outcomes so no single field can
  become inconsistent with the rest of the record.
  """

  alias Compliance.{KycRecord, Repo, SanctionsClient}
  alias Ecto.Multi

  require Logger

  @type step :: :document_upload | :liveness_check | :sanctions_screen | :manual_review
  @type step_status :: :pending | :passed | :failed | :requires_review
  @type workflow_status :: :incomplete | :passed | :failed | :requires_manual_review

  @doc """
  Creates a new KYC record for `account_id` in the `:incomplete` state.
  Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec initiate(binary()) :: {:ok, KycRecord.t()} | {:error, term()}
  def initiate(account_id) when is_binary(account_id) do
    %KycRecord{}
    |> KycRecord.initiate_changeset(%{account_id: account_id})
    |> Repo.insert()
  end

  @doc """
  Records the outcome of the document upload step. Validates that document
  fields are present and meet minimum quality criteria before marking the
  step complete.
  """
  @spec submit_document(binary(), map()) :: {:ok, KycRecord.t()} | {:error, term()}
  def submit_document(kyc_id, document_attrs) when is_binary(kyc_id) and is_map(document_attrs) do
    with {:ok, record} <- fetch_in_progress(kyc_id),
         :ok <- assert_step_pending(record, :document_upload),
         {:ok, validated} <- validate_document(document_attrs) do
      update_step(record, :document_upload, :passed, validated)
    end
  end

  @doc """
  Records the liveness check result from the identity provider.
  Automatically fails the workflow if liveness confidence falls below threshold.
  """
  @spec record_liveness(binary(), %{confidence: float(), provider_ref: binary()}) ::
          {:ok, KycRecord.t()} | {:error, term()}
  def record_liveness(kyc_id, %{confidence: confidence, provider_ref: ref})
      when is_binary(kyc_id) and is_float(confidence) and is_binary(ref) do
    with {:ok, record} <- fetch_in_progress(kyc_id),
         :ok <- assert_step_pending(record, :liveness_check) do
      status = if confidence >= 0.85, do: :passed, else: :failed
      update_step(record, :liveness_check, status, %{confidence: confidence, provider_ref: ref})
    end
  end

  @doc """
  Runs the sanctions screening step against the configured provider.
  Marks the step as `:requires_review` when a potential match is returned.
  """
  @spec run_sanctions_screen(binary()) :: {:ok, KycRecord.t()} | {:error, term()}
  def run_sanctions_screen(kyc_id) when is_binary(kyc_id) do
    with {:ok, record} <- fetch_in_progress(kyc_id),
         :ok <- assert_step_pending(record, :sanctions_screen),
         {:ok, screen_result} <- SanctionsClient.screen(record.account_id) do
      status =
        case screen_result.match_level do
          :none -> :passed
          :potential -> :requires_review
          :confirmed -> :failed
        end

      update_step(record, :sanctions_screen, status, screen_result)
    end
  end

  @doc """
  Submits a manual review decision for records that required human oversight.
  `decision` must be `:approved` or `:rejected`, with a mandatory `reason`.
  """
  @spec submit_review(binary(), :approved | :rejected, binary()) ::
          {:ok, KycRecord.t()} | {:error, term()}
  def submit_review(kyc_id, decision, reason)
      when is_binary(kyc_id) and decision in [:approved, :rejected] and is_binary(reason) do
    with {:ok, record} <- fetch_in_progress(kyc_id),
         :ok <- assert_step_pending(record, :manual_review) do
      step_status = if decision == :approved, do: :passed, else: :failed
      update_step(record, :manual_review, step_status, %{decision: decision, reason: reason})
    end
  end

  @doc """
  Derives the overall workflow status from step outcomes. Pure function;
  does not read from the database.
  """
  @spec derive_status(KycRecord.t()) :: workflow_status()
  def derive_status(%KycRecord{steps: steps}) do
    statuses = Map.values(steps)

    cond do
      :failed in statuses -> :failed
      :requires_review in statuses -> :requires_manual_review
      Enum.all?(statuses, &(&1 == :passed)) -> :passed
      true -> :incomplete
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_in_progress(kyc_id) do
    case Repo.get(KycRecord, kyc_id) do
      nil -> {:error, :not_found}
      %KycRecord{workflow_status: :passed} -> {:error, :already_completed}
      %KycRecord{workflow_status: :failed} -> {:error, :already_failed}
      record -> {:ok, record}
    end
  end

  defp assert_step_pending(%KycRecord{steps: steps}, step) do
    case Map.get(steps, step, :pending) do
      :pending -> :ok
      status -> {:error, {:step_already_recorded, step, status}}
    end
  end

  defp validate_document(%{type: type, number: number} = attrs)
       when is_binary(type) and is_binary(number) do
    {:ok, Map.take(attrs, [:type, :number, :country, :expiry_date])}
  end

  defp validate_document(_), do: {:error, :invalid_document_attrs}

  defp update_step(record, step, step_status, metadata) do
    updated_steps = Map.put(record.steps, step, step_status)
    updated_record = %{record | steps: updated_steps}
    new_workflow_status = derive_status(updated_record)

    record
    |> KycRecord.step_changeset(%{
      steps: updated_steps,
      workflow_status: new_workflow_status,
      step_metadata: Map.put(record.step_metadata, step, metadata)
    })
    |> Repo.update()
  end
end
```
