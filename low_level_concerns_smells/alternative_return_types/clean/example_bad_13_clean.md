```elixir
defmodule MyApp.Support.Ticket do
  @moduledoc """
  Customer support ticket lifecycle management. Handles creation, assignment,
  escalation, resolution, and customer notification for the helpdesk system.
  """

  alias MyApp.Support.Note
  alias MyApp.Support.Assignment
  alias MyApp.Notifications.Dispatcher
  alias MyApp.Repo

  @statuses [:open, :in_progress, :pending_customer, :resolved, :closed]
  @escalation_sla_hours 4
  @resolution_sla_hours 24

  defstruct [
    :id, :subject, :body, :customer_id,
    :assignee_id, :status, :priority,
    :tags, :opened_at, :resolved_at,
    :sla_deadline, :notes
  ]

  def open(customer_id, subject, body, opts \\ []) do
    priority = Keyword.get(opts, :priority, :normal)

    %__MODULE__{
      id: generate_id(),
      subject: subject,
      body: body,
      customer_id: customer_id,
      status: :open,
      priority: priority,
      tags: opts[:tags] || [],
      opened_at: DateTime.utc_now(),
      sla_deadline: DateTime.add(DateTime.utc_now(), @resolution_sla_hours * 3600, :second),
      notes: []
    }
  end

  def resolve(ticket, opts \\ []) when is_list(opts) do
    reply = Keyword.get(opts, :reply, :silent)
    resolution_note = Keyword.get(opts, :note, "Resolved.")
    notify_customer = Keyword.get(opts, :notify_customer, true)

    resolved = %{
      ticket
      | status: :resolved,
        resolved_at: DateTime.utc_now(),
        notes: ticket.notes ++ [Note.new(:system, resolution_note)]
    }

    Repo.update!(resolved)

    case reply do
      :silent ->
        resolved

      :notify ->
        receipt =
          if notify_customer do
            Dispatcher.send(
              %{id: resolved.customer_id},
              %{
                template: :ticket_resolved,
                assigns: %{
                  ticket_id: resolved.id,
                  subject: resolved.subject,
                  note: resolution_note
                }
              },
              channel: :email,
              ack: :receipt
            )
          else
            :skipped
          end

        {:ok, resolved, receipt}

      :bare ->
        :ok
    end
  end

  def assign(ticket, agent_id) do
    updated = %{ticket | assignee_id: agent_id, status: :in_progress}
    Assignment.record(ticket.id, agent_id)
    Repo.update!(updated)
    {:ok, updated}
  end

  def escalate(ticket, reason) do
    new_deadline = DateTime.add(DateTime.utc_now(), @escalation_sla_hours * 3600, :second)
    updated = %{ticket | priority: :high, sla_deadline: new_deadline}
    Repo.update!(updated)
    {:ok, updated}
  end

  def add_note(ticket, author_id, content) do
    note = Note.new(author_id, content)
    updated = %{ticket | notes: ticket.notes ++ [note]}
    Repo.update!(updated)
    {:ok, updated}
  end

  def breached_sla?(%__MODULE__{sla_deadline: deadline, status: status}) do
    status not in [:resolved, :closed] and
      DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  defp generate_id do
    "TKT-" <> (:crypto.strong_rand_bytes(5) |> Base.encode16())
  end
end
```
