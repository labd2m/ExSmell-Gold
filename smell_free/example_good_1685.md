```elixir
defmodule Approvals.WorkflowChain do
  @moduledoc """
  Manages multi-level approval workflows where requests must be approved
  by each level in sequence before proceeding. Supports parallel approvals
  at each level and automatic escalation on timeout.
  """

  alias Approvals.{Repo, ApprovalRequest, ApprovalDecision, Notifier}
  alias Ecto.Multi

  @type request_id :: String.t()
  @type approver_id :: String.t()
  @type decision :: :approved | :rejected

  @spec submit(map()) :: {:ok, ApprovalRequest.t()} | {:error, Ecto.Changeset.t()}
  def submit(params) when is_map(params) do
    Multi.new()
    |> Multi.insert(:request, ApprovalRequest.creation_changeset(%ApprovalRequest{}, params))
    |> Multi.run(:notify, fn _repo, %{request: req} ->
      notify_level_approvers(req, 1)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{request: request}} -> {:ok, request}
      {:error, :request, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @spec decide(request_id(), approver_id(), decision(), String.t() | nil) ::
          {:ok, ApprovalRequest.t()} | {:error, :not_found | :not_authorized | :already_decided | atom()}
  def decide(request_id, approver_id, decision, comment \\ nil)
      when decision in [:approved, :rejected] do
    with {:ok, request} <- fetch_pending(request_id),
         :ok <- verify_approver(request, approver_id),
         :ok <- check_not_already_decided(request, approver_id) do
      record_decision(request, approver_id, decision, comment)
    end
  end

  @spec fetch(request_id()) :: {:ok, ApprovalRequest.t()} | {:error, :not_found}
  def fetch(request_id) when is_binary(request_id) do
    case Repo.get(ApprovalRequest, request_id) |> Repo.preload(:decisions) do
      nil -> {:error, :not_found}
      req -> {:ok, req}
    end
  end

  @spec record_decision(ApprovalRequest.t(), approver_id(), decision(), String.t() | nil) ::
          {:ok, ApprovalRequest.t()} | {:error, atom()}
  defp record_decision(request, approver_id, decision, comment) do
    Multi.new()
    |> Multi.insert(:decision, ApprovalDecision.creation_changeset(%ApprovalDecision{}, %{
      request_id: request.id,
      approver_id: approver_id,
      decision: decision,
      comment: comment,
      decided_at: DateTime.utc_now()
    }))
    |> Multi.run(:advance, fn _repo, %{decision: recorded_decision} ->
      advance_workflow(request, recorded_decision)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{advance: updated}} -> {:ok, updated}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @spec advance_workflow(ApprovalRequest.t(), ApprovalDecision.t()) ::
          {:ok, ApprovalRequest.t()} | {:error, Ecto.Changeset.t()}
  defp advance_workflow(request, decision) do
    cond do
      decision.decision == :rejected ->
        update_status(request, :rejected)

      level_complete?(request, decision) and request.current_level >= request.total_levels ->
        update_status(request, :approved)

      level_complete?(request, decision) ->
        next_level = request.current_level + 1
        updated = request |> ApprovalRequest.level_changeset(next_level) |> Repo.update!()
        notify_level_approvers(updated, next_level)
        {:ok, updated}

      true ->
        {:ok, request}
    end
  end

  @spec level_complete?(ApprovalRequest.t(), ApprovalDecision.t()) :: boolean()
  defp level_complete?(request, _decision) do
    level_approvers = Enum.filter(request.approvers, &(&1.level == request.current_level))
    decisions_at_level = Enum.count(request.decisions, &(&1.level == request.current_level))
    required = request.required_approvals_per_level
    decisions_at_level >= min(required, length(level_approvers))
  end

  @spec update_status(ApprovalRequest.t(), atom()) ::
          {:ok, ApprovalRequest.t()} | {:error, Ecto.Changeset.t()}
  defp update_status(request, status) do
    request
    |> ApprovalRequest.status_changeset(status, %{resolved_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @spec fetch_pending(request_id()) :: {:ok, ApprovalRequest.t()} | {:error, :not_found | :not_pending}
  defp fetch_pending(request_id) do
    case Repo.get(ApprovalRequest, request_id) |> Repo.preload([:decisions, :approvers]) do
      nil -> {:error, :not_found}
      %{status: :pending} = req -> {:ok, req}
      _ -> {:error, :not_pending}
    end
  end

  @spec verify_approver(ApprovalRequest.t(), approver_id()) :: :ok | {:error, :not_authorized}
  defp verify_approver(request, approver_id) do
    current_level_approvers = Enum.filter(request.approvers, &(&1.level == request.current_level))
    if Enum.any?(current_level_approvers, &(&1.user_id == approver_id)) do
      :ok
    else
      {:error, :not_authorized}
    end
  end

  @spec check_not_already_decided(ApprovalRequest.t(), approver_id()) :: :ok | {:error, :already_decided}
  defp check_not_already_decided(request, approver_id) do
    if Enum.any?(request.decisions, &(&1.approver_id == approver_id)) do
      {:error, :already_decided}
    else
      :ok
    end
  end

  @spec notify_level_approvers(ApprovalRequest.t(), pos_integer()) :: {:ok, non_neg_integer()}
  defp notify_level_approvers(request, level) do
    approvers = Enum.filter(request.approvers || [], &(&1.level == level))
    Enum.each(approvers, &Notifier.notify_approver(&1.user_id, request))
    {:ok, length(approvers)}
  end
end
```
