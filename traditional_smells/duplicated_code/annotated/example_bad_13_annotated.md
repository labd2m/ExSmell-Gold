# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Orders.StatusManager.mark_shipped/2` and `Orders.StatusManager.mark_delivered/2` |
| **Affected functions** | `mark_shipped/2`, `mark_delivered/2` |
| **Short explanation** | Both functions duplicate the logic for building the status history entry — constructing a map with the new status, timestamp, actor ID, and notes, then prepending it to the existing history list. If the history entry schema changes, both functions must be updated. |

```elixir
defmodule Orders.StatusManager do
  @moduledoc """
  Manages order status transitions and maintains an audit trail
  of all status changes with actor attribution.
  """

  alias Orders.Repo
  alias Orders.Order
  alias Orders.Notification

  @valid_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:processing, :cancelled],
    processing: [:shipped, :cancelled],
    shipped: [:delivered, :returned],
    delivered: [:returned]
  }

  @doc """
  Transitions an order to :shipped status and records a tracking number.
  """
  def mark_shipped(%Order{} = order, %{actor_id: actor_id, tracking_number: tracking, notes: notes}) do
    with :ok <- validate_transition(order.status, :shipped) do
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the status history entry map
      # construction and prepend logic is duplicated in mark_delivered/2.
      # If a new field is added to history entries (e.g., IP address), it must
      # be added in both functions.
      history_entry = %{
        status: :shipped,
        timestamp: DateTime.utc_now(),
        actor_id: actor_id,
        notes: notes
      }

      updated_history = [history_entry | order.status_history || []]
      # VALIDATION: SMELL END

      updated_order = %{
        order
        | status: :shipped,
          tracking_number: tracking,
          shipped_at: DateTime.utc_now(),
          status_history: updated_history
      }

      with {:ok, saved} <- Repo.update(updated_order) do
        Notification.send(saved, :order_shipped)
        {:ok, saved}
      end
    end
  end

  @doc """
  Transitions an order to :delivered status and records delivery confirmation.
  """
  def mark_delivered(%Order{} = order, %{actor_id: actor_id, proof_of_delivery: pod, notes: notes}) do
    with :ok <- validate_transition(order.status, :delivered) do
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because this history entry construction
      # is a copy of the one in mark_shipped/2.
      history_entry = %{
        status: :delivered,
        timestamp: DateTime.utc_now(),
        actor_id: actor_id,
        notes: notes
      }

      updated_history = [history_entry | order.status_history || []]
      # VALIDATION: SMELL END

      updated_order = %{
        order
        | status: :delivered,
          delivered_at: DateTime.utc_now(),
          proof_of_delivery: pod,
          status_history: updated_history
      }

      with {:ok, saved} <- Repo.update(updated_order) do
        Notification.send(saved, :order_delivered)
        {:ok, saved}
      end
    end
  end

  @doc """
  Cancels an order if the transition is valid.
  """
  def cancel(%Order{} = order, reason) do
    with :ok <- validate_transition(order.status, :cancelled) do
      updated = %{order | status: :cancelled, cancel_reason: reason, cancelled_at: DateTime.utc_now()}
      Repo.update(updated)
    end
  end

  @doc """
  Returns the full status transition history for an order.
  """
  def history(%Order{} = order) do
    order.status_history |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
  end

  defp validate_transition(from, to) do
    allowed = Map.get(@valid_transitions, from, [])
    if to in allowed, do: :ok, else: {:error, {:invalid_transition, from, to}}
  end
end
```
