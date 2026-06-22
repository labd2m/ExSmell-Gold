# File: `example_good_704.md`

```elixir
defmodule Payments.DisputeTracker do
  @moduledoc """
  Manages the lifecycle of payment disputes (chargebacks) from initial
  notice through evidence submission, resolution, and fund recovery.

  Disputes follow a strict state machine. Evidence must be submitted
  before the deadline stored on the dispute. All state transitions are
  recorded with a timestamp so the audit trail is fully reconstructable.
  """

  import Ecto.Query, warn: false

  alias Payments.{Dispute, DisputeEvidence, Repo}

  @type dispute_id :: Ecto.UUID.t()
  @type payment_id :: Ecto.UUID.t()

  @type dispute_status ::
          :needs_response
          | :under_review
          | :won
          | :lost
          | :accepted
          | :withdrawn

  @type transition_result ::
          {:ok, Dispute.t()} | {:error, :invalid_transition | Ecto.Changeset.t()}

  @valid_transitions %{
    needs_response: [:under_review, :accepted],
    under_review: [:won, :lost],
    won: [],
    lost: [],
    accepted: [],
    withdrawn: []
  }

  @doc """
  Opens a new dispute record from an inbound chargeback notification.
  """
  @spec open(payment_id(), String.t(), Date.t()) ::
          {:ok, Dispute.t()} | {:error, Ecto.Changeset.t()}
  def open(payment_id, reason, evidence_due_by)
      when is_binary(payment_id) and is_binary(reason) do
    %{
      payment_id: payment_id,
      reason: reason,
      status: :needs_response,
      evidence_due_by: evidence_due_by,
      opened_at: DateTime.utc_now()
    }
    |> Dispute.changeset()
    |> Repo.insert()
  end

  @doc """
  Attaches an evidence document to an open dispute.

  Returns `{:error, :evidence_deadline_passed}` when the submission
  window has closed.
  """
  @spec submit_evidence(Dispute.t(), map()) ::
          {:ok, DisputeEvidence.t()} | {:error, atom() | Ecto.Changeset.t()}
  def submit_evidence(%Dispute{status: :needs_response, evidence_due_by: due_by} = dispute, evidence_attrs)
      when is_map(evidence_attrs) do
    if Date.compare(Date.utc_today(), due_by) == :gt do
      {:error, :evidence_deadline_passed}
    else
      insert_evidence(dispute, evidence_attrs)
    end
  end

  def submit_evidence(%Dispute{}, _attrs), do: {:error, :dispute_not_accepting_evidence}

  @doc """
  Transitions a dispute to `new_status`.

  Returns `{:error, :invalid_transition}` for disallowed state changes.
  """
  @spec transition(Dispute.t(), dispute_status()) :: transition_result()
  def transition(%Dispute{status: current} = dispute, new_status) when is_atom(new_status) do
    allowed = Map.get(@valid_transitions, current, [])

    if new_status in allowed do
      dispute
      |> Dispute.status_changeset(%{status: new_status, "#{new_status}_at": DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Returns all disputes for a given payment, ordered by most recent first.
  """
  @spec list_for_payment(payment_id()) :: [Dispute.t()]
  def list_for_payment(payment_id) when is_binary(payment_id) do
    Dispute
    |> where([d], d.payment_id == ^payment_id)
    |> order_by([d], desc: d.opened_at)
    |> preload(:evidence)
    |> Repo.all()
  end

  @doc """
  Returns all disputes with evidence due within the next `days` calendar days.
  """
  @spec approaching_deadlines(pos_integer()) :: [Dispute.t()]
  def approaching_deadlines(days) when is_integer(days) and days > 0 do
    cutoff = Date.add(Date.utc_today(), days)

    Dispute
    |> where([d], d.status == :needs_response and d.evidence_due_by <= ^cutoff)
    |> order_by([d], asc: d.evidence_due_by)
    |> Repo.all()
  end

  @doc """
  Returns a summary of dispute outcomes grouped by status.
  """
  @spec outcome_summary() :: %{dispute_status() => non_neg_integer()}
  def outcome_summary do
    Dispute
    |> group_by([d], d.status)
    |> select([d], {d.status, count(d.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp insert_evidence(dispute, attrs) do
    attrs
    |> Map.put(:dispute_id, dispute.id)
    |> DisputeEvidence.changeset()
    |> Repo.insert()
  end
end
```
