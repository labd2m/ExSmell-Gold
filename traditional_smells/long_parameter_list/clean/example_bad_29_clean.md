```elixir
defmodule Support.Tickets do
  @moduledoc """
  Handles inbound support ticket creation, routing, SLA assignment,
  and acknowledgement emails.
  """

  require Logger

  alias Support.Repo
  alias Support.Schemas.Ticket
  alias Support.Schemas.Attachment
  alias Support.SLAPolicy
  alias Support.TeamRouter
  alias Support.Mailer

  @valid_categories ~w(billing technical account general)
  @valid_priorities ~w(low normal high urgent)
  @max_attachments 5

  def create_ticket(
        requester_id,
        requester_email,
        requester_name,
        subject,
        body,
        attachments,
        category,
        priority,
        assigned_team_id,
        send_confirmation
      ) do
    with :ok <- validate_subject(subject),
         :ok <- validate_body(body),
         :ok <- validate_category(category),
         :ok <- validate_priority(priority),
         :ok <- validate_attachments(attachments) do
      team_id = assigned_team_id || TeamRouter.route(category, priority)
      sla = SLAPolicy.for(category, priority)

      due_at = DateTime.add(DateTime.utc_now(), sla.response_minutes * 60, :second)

      ticket_attrs = %{
        requester_id: requester_id,
        requester_email: requester_email,
        requester_name: requester_name,
        subject: String.trim(subject),
        body: body,
        category: category,
        priority: priority,
        assigned_team_id: team_id,
        sla_due_at: due_at,
        status: :open,
        inserted_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        case Repo.insert(Ticket.changeset(%Ticket{}, ticket_attrs)) do
          {:ok, ticket} ->
            Enum.each(attachments || [], fn att ->
              Repo.insert!(Attachment.changeset(%Attachment{}, %{
                ticket_id: ticket.id,
                filename: att.filename,
                url: att.url,
                size_bytes: att.size_bytes
              }))
            end)

            if send_confirmation do
              Mailer.send_ticket_confirmation(requester_email, requester_name, ticket)
            end

            Logger.info("Ticket #{ticket.id} created [#{priority}] for #{requester_email}")
            ticket

          {:error, changeset} ->
            Logger.error("Ticket creation failed: #{inspect(changeset.errors)}")
            Repo.rollback(:creation_failed)
        end
      end)
    end
  end

  defp validate_subject(s) do
    if is_binary(s) and String.length(String.trim(s)) >= 5 do
      :ok
    else
      {:error, :subject_too_short}
    end
  end

  defp validate_body(b) do
    if is_binary(b) and String.length(String.trim(b)) >= 10 do
      :ok
    else
      {:error, :body_too_short}
    end
  end

  defp validate_category(c) when c in @valid_categories, do: :ok
  defp validate_category(c), do: {:error, {:unknown_category, c}}

  defp validate_priority(p) when p in @valid_priorities, do: :ok
  defp validate_priority(p), do: {:error, {:unknown_priority, p}}

  defp validate_attachments(nil), do: :ok
  defp validate_attachments(list) when length(list) <= @max_attachments, do: :ok
  defp validate_attachments(_), do: {:error, :too_many_attachments}
end
```
