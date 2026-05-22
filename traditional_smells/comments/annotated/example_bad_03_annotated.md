# Annotated Example 03

## Metadata

- **Smell name:** Comments
- **Expected smell location:** `ShipmentTracker.update_shipment_status/3`
- **Affected function(s):** `update_shipment_status/3`
- **Short explanation:** Explanatory comments are used in place of `@doc` to describe the function's purpose, side effects, and return values. This makes the documentation inaccessible through standard Elixir tooling.

---

## Code

```elixir
defmodule ShipmentTracker do
  @moduledoc """
  Manages the lifecycle and status transitions of shipments within the logistics platform.
  """

  alias ShipmentTracker.{Shipment, StatusEvent, NotificationDispatcher, AuditLog}

  @valid_transitions %{
    pending: [:picked_up, :cancelled],
    picked_up: [:in_transit, :exception],
    in_transit: [:out_for_delivery, :exception, :returned],
    out_for_delivery: [:delivered, :failed_attempt, :exception],
    failed_attempt: [:out_for_delivery, :returned],
    exception: [:in_transit, :returned, :cancelled],
    delivered: [],
    returned: [],
    cancelled: []
  }

  @doc """
  Returns the list of valid next statuses for a given current status.
  """
  def valid_next_statuses(current_status) do
    Map.get(@valid_transitions, current_status, [])
  end

  # update_shipment_status/3
  #
  # Transitions a shipment to a new status, enforcing the allowed transition
  # matrix defined in @valid_transitions. On a successful transition the
  # function performs three side effects:
  #   - Persists a StatusEvent record with the actor, timestamp, and optional note.
  #   - Appends an entry to the AuditLog for compliance tracing.
  #   - Dispatches a push/email notification via NotificationDispatcher if the
  #     new status is :delivered, :failed_attempt, or :exception.
  #
  # Arguments:
  #   shipment_id  - integer primary key of the shipment
  #   new_status   - atom representing the target status
  #   actor        - map with :id and :type (:driver | :system | :agent)
  #
  # Returns {:ok, updated_shipment} or {:error, reason}.
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because update_shipment_status/3 is fully explained
  # through plain comments rather than an @doc attribute. The documentation is therefore
  # invisible to IEx.h/1, ExDoc, and language-server tooling.
  def update_shipment_status(shipment_id, new_status, actor) do
    with {:ok, shipment} <- fetch_shipment(shipment_id),
         :ok <- validate_transition(shipment.status, new_status),
         {:ok, updated} <- persist_status_change(shipment, new_status),
         {:ok, _event} <- StatusEvent.record(shipment_id, new_status, actor),
         :ok <- AuditLog.append(shipment_id, actor, shipment.status, new_status) do
      maybe_notify(updated, new_status)
      {:ok, updated}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the full status history for a shipment ordered by insertion time.
  """
  def status_history(shipment_id) do
    StatusEvent.all_for_shipment(shipment_id)
  end

  @doc """
  Cancels a shipment if it is still in a cancellable state.
  """
  def cancel(shipment_id, actor) do
    update_shipment_status(shipment_id, :cancelled, actor)
  end

  defp fetch_shipment(id) do
    case Repo.get(Shipment, id) do
      nil -> {:error, :not_found}
      shipment -> {:ok, shipment}
    end
  end

  defp validate_transition(current, next) do
    allowed = Map.get(@valid_transitions, current, [])

    if next in allowed do
      :ok
    else
      {:error, {:invalid_transition, current, next}}
    end
  end

  defp persist_status_change(shipment, new_status) do
    shipment
    |> Shipment.changeset(%{status: new_status, updated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp maybe_notify(shipment, status) when status in [:delivered, :failed_attempt, :exception] do
    NotificationDispatcher.dispatch(shipment, status)
  end

  defp maybe_notify(_shipment, _status), do: :ok
end
```
