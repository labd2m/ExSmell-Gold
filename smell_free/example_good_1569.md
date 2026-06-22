```elixir
defmodule Content.Publishing.WorkflowCoordinator do
  @moduledoc """
  Coordinates multi-step content publishing workflows with reviewer assignments.

  Manages draft, review, approval, and publication state transitions for
  content items, with per-step assignment tracking and audit logging.
  """

  alias Content.Publishing.{ContentItem, Reviewer, AuditLog, PublicationGateway}
  alias Content.Repo
  import Ecto.Query, warn: false

  @type transition_result ::
          {:ok, ContentItem.t()}
          | {:error, :invalid_state}
          | {:error, :reviewer_not_eligible}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Submits a draft content item for editorial review.

  Returns the updated item with status `:in_review` and the assigned reviewer.
  """
  @spec submit_for_review(ContentItem.t(), Reviewer.t()) :: transition_result()
  def submit_for_review(%ContentItem{status: :draft} = item, %Reviewer{} = reviewer) do
    with :ok <- verify_reviewer_eligibility(reviewer, item),
         {:ok, updated} <- transition(item, :in_review, %{assigned_reviewer_id: reviewer.id}) do
      AuditLog.record(:submitted_for_review, item.id, reviewer.id)
      {:ok, updated}
    end
  end

  def submit_for_review(%ContentItem{}, _reviewer), do: {:error, :invalid_state}

  @doc """
  Records a review decision on a content item currently in review.

  Accepted items move to `:approved`; rejected items return to `:draft`.
  """
  @spec record_review_decision(ContentItem.t(), Reviewer.t(), :approved | :rejected, String.t()) ::
          transition_result()
  def record_review_decision(%ContentItem{status: :in_review} = item, reviewer, decision, notes)
      when decision in [:approved, :rejected] do
    target_status = decision_to_status(decision)

    with {:ok, updated} <- transition(item, target_status, %{review_notes: notes}) do
      AuditLog.record(decision, item.id, reviewer.id, notes)
      {:ok, updated}
    end
  end

  def record_review_decision(%ContentItem{}, _reviewer, _decision, _notes) do
    {:error, :invalid_state}
  end

  @doc """
  Publishes an approved content item to the publication gateway.

  Moves the item to `:published` status upon successful gateway response.
  """
  @spec publish(ContentItem.t(), String.t()) :: transition_result()
  def publish(%ContentItem{status: :approved} = item, publisher_id) do
    with :ok <- PublicationGateway.publish(item),
         {:ok, updated} <- transition(item, :published, %{published_by: publisher_id}) do
      AuditLog.record(:published, item.id, publisher_id)
      {:ok, updated}
    end
  end

  def publish(%ContentItem{}, _publisher_id), do: {:error, :invalid_state}

  @doc """
  Lists all content items currently assigned to a specific reviewer.
  """
  @spec items_for_reviewer(String.t()) :: [ContentItem.t()]
  def items_for_reviewer(reviewer_id) when is_binary(reviewer_id) do
    ContentItem
    |> where([c], c.assigned_reviewer_id == ^reviewer_id and c.status == :in_review)
    |> order_by([c], asc: c.inserted_at)
    |> Repo.all()
  end

  defp decision_to_status(:approved), do: :approved
  defp decision_to_status(:rejected), do: :draft

  defp transition(item, new_status, extra_attrs) do
    attrs = Map.merge(extra_attrs, %{status: new_status})

    item
    |> ContentItem.transition_changeset(attrs)
    |> Repo.update()
  end

  defp verify_reviewer_eligibility(%Reviewer{active: false}, _item) do
    {:error, :reviewer_not_eligible}
  end

  defp verify_reviewer_eligibility(%Reviewer{id: rid}, %ContentItem{author_id: aid})
       when rid == aid do
    {:error, :reviewer_not_eligible}
  end

  defp verify_reviewer_eligibility(%Reviewer{}, %ContentItem{}), do: :ok
end
```
