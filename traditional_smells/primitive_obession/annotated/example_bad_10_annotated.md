# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `transition_status/2`, `valid_transition?/2`, `apply_status_action/2`, `status_label/1`
- **Affected Function(s)**: All public functions in `Billing.InvoiceStateMachine`
- **Explanation**: Invoice lifecycle status is modelled as a plain `String.t()` (e.g., `"draft"`, `"pending"`, `"paid"`) instead of a dedicated type, struct, or even an atom-based enumeration. This scatters the valid-values list, transition rules, and label mappings into separate ad-hoc checks, and allows any arbitrary string to be passed where only a constrained set of states makes sense.

## Code

```elixir
defmodule Billing.InvoiceStateMachine do
  @moduledoc """
  Manages invoice lifecycle transitions for the billing subsystem.
  Enforces a strict directed graph of allowed state transitions and
  records each transition with an actor reference and timestamp for
  audit purposes.
  """

  require Logger

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because invoice status is modelled as a raw
  # VALIDATION: `String.t()` (e.g., "draft", "pending", "paid", "voided")
  # VALIDATION: instead of a dedicated type such as an `@type t :: :draft |
  # VALIDATION: :pending | :paid | :voided` or a `%InvoiceStatus{}` struct.
  # VALIDATION: Valid values, allowed transitions, and display labels are all
  # VALIDATION: maintained as separate string-based lookups with no compile-time
  # VALIDATION: guarantee that an unknown status can never be introduced.
  @valid_statuses ~w(draft pending sent overdue paid partial voided disputed)

  @transitions %{
    "draft" => ~w(pending voided),
    "pending" => ~w(sent voided),
    "sent" => ~w(paid partial overdue voided disputed),
    "overdue" => ~w(paid partial voided disputed),
    "partial" => ~w(paid overdue voided disputed),
    "disputed" => ~w(paid voided sent),
    "paid" => [],
    "voided" => []
  }

  @spec transition_status(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def transition_status(current_status, target_status) do
    with :ok <- validate_status(current_status),
         :ok <- validate_status(target_status),
         true <- valid_transition?(current_status, target_status) do
      Logger.info("Invoice status transition: #{current_status} → #{target_status}")
      {:ok, target_status}
    else
      false ->
        {:error,
         "Invalid transition from '#{current_status}' to '#{target_status}'. " <>
           "Allowed: #{allowed_transitions(current_status) |> Enum.join(", ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(from_status, to_status) do
    case Map.get(@transitions, from_status) do
      nil -> false
      allowed -> to_status in allowed
    end
  end

  @spec allowed_transitions(String.t()) :: list(String.t())
  def allowed_transitions(status) do
    Map.get(@transitions, status, [])
  end

  @spec apply_status_action(map(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_status_action(invoice, actor_id) do
    action = derive_action(invoice.status)

    case action do
      "send" ->
        transition_and_record(invoice, "sent", actor_id)

      "mark_paid" ->
        transition_and_record(invoice, "paid", actor_id)

      "void" ->
        transition_and_record(invoice, "voided", actor_id)

      "escalate" ->
        transition_and_record(invoice, "overdue", actor_id)

      nil ->
        {:error, "No automated action available for status '#{invoice.status}'"}
    end
  end

  @spec status_label(String.t()) :: String.t()
  def status_label(status) do
    case status do
      "draft" -> "Draft"
      "pending" -> "Pending Approval"
      "sent" -> "Sent to Customer"
      "overdue" -> "Overdue"
      "paid" -> "Paid in Full"
      "partial" -> "Partially Paid"
      "voided" -> "Voided"
      "disputed" -> "Under Dispute"
      other -> "Unknown (#{other})"
    end
  end

  @spec terminal_status?(String.t()) :: boolean()
  def terminal_status?(status) do
    allowed_transitions(status) == []
  end
  # VALIDATION: SMELL END

  defp transition_and_record(invoice, target_status, actor_id) do
    with {:ok, new_status} <- transition_status(invoice.status, target_status) do
      updated =
        invoice
        |> Map.put(:status, new_status)
        |> Map.update(:history, [], fn h ->
          [%{from: invoice.status, to: new_status, actor: actor_id, at: DateTime.utc_now()} | h]
        end)

      {:ok, updated}
    end
  end

  defp derive_action("draft"), do: "send"
  defp derive_action("pending"), do: "send"
  defp derive_action("sent"), do: "escalate"
  defp derive_action("overdue"), do: "escalate"
  defp derive_action(_), do: nil

  defp validate_status(status) do
    if status in @valid_statuses do
      :ok
    else
      {:error,
       "Unknown status '#{status}'. Valid statuses: #{Enum.join(@valid_statuses, ", ")}"}
    end
  end
end
```
