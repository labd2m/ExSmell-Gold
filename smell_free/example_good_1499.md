```elixir
defmodule Support.TicketContext do
  @moduledoc """
  Manages support ticket lifecycle including creation, assignment, resolution, and escalation.
  Enforces valid status transitions and records all state changes with timestamps.
  """

  alias Support.{Ticket, Repo, TicketEvent}
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 3]

  @type open_filters :: [assigned_to: String.t(), priority: Ticket.priority()]

  @spec open_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def open_ticket(params) when is_map(params) do
    Repo.transaction(fn ->
      with {:ok, ticket} <- insert_ticket(params),
           {:ok, _event} <- record_event(ticket, :opened, nil) do
        ticket
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec assign_ticket(Ticket.t(), String.t()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def assign_ticket(%Ticket{status: status} = ticket, agent_id)
      when status in [:open, :escalated] and is_binary(agent_id) do
    Repo.transaction(fn ->
      with {:ok, updated} <- update_ticket(ticket, %{assigned_to: agent_id, status: :in_progress}),
           {:ok, _event} <- record_event(updated, :assigned, %{agent_id: agent_id}) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def assign_ticket(%Ticket{status: status}, _agent_id) do
    {:error, "Cannot assign ticket with status: #{status}"}
  end

  @spec resolve_ticket(Ticket.t(), String.t()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def resolve_ticket(%Ticket{status: :in_progress} = ticket, resolution)
      when is_binary(resolution) do
    Repo.transaction(fn ->
      with {:ok, updated} <- update_ticket(ticket, %{status: :resolved, resolution: resolution}),
           {:ok, _event} <- record_event(updated, :resolved, %{resolution: resolution}) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def resolve_ticket(%Ticket{status: status}, _resolution) do
    {:error, "Cannot resolve ticket with status: #{status}"}
  end

  @spec escalate_ticket(Ticket.t(), String.t()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def escalate_ticket(%Ticket{status: status} = ticket, reason)
      when status in [:open, :in_progress] and is_binary(reason) do
    Repo.transaction(fn ->
      with {:ok, updated} <- update_ticket(ticket, %{status: :escalated, priority: :critical}),
           {:ok, _event} <- record_event(updated, :escalated, %{reason: reason}) do
        updated
      else
        {:error, err} -> Repo.rollback(err)
      end
    end)
  end

  def escalate_ticket(%Ticket{status: status}, _reason) do
    {:error, "Cannot escalate ticket with status: #{status}"}
  end

  @spec list_open(open_filters()) :: [Ticket.t()]
  def list_open(filters \\ []) do
    from(t in Ticket, where: t.status in [:open, :in_progress, :escalated])
    |> apply_assignment_filter(filters)
    |> apply_priority_filter(filters)
    |> order_by([t], [asc: t.priority, asc: t.inserted_at])
    |> Repo.all()
  end

  @spec insert_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  defp insert_ticket(params) do
    params |> Ticket.creation_changeset() |> Repo.insert()
  end

  @spec update_ticket(Ticket.t(), map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  defp update_ticket(ticket, params) do
    ticket |> Ticket.status_changeset(params) |> Repo.update()
  end

  @spec record_event(Ticket.t(), atom(), map() | nil) ::
          {:ok, TicketEvent.t()} | {:error, Ecto.Changeset.t()}
  defp record_event(ticket, action, metadata) do
    %{ticket_id: ticket.id, action: action, metadata: metadata || %{}}
    |> TicketEvent.changeset()
    |> Repo.insert()
  end

  @spec apply_assignment_filter(Ecto.Query.t(), open_filters()) :: Ecto.Query.t()
  defp apply_assignment_filter(query, filters) do
    case Keyword.get(filters, :assigned_to) do
      nil -> query
      agent_id -> where(query, [t], t.assigned_to == ^agent_id)
    end
  end

  @spec apply_priority_filter(Ecto.Query.t(), open_filters()) :: Ecto.Query.t()
  defp apply_priority_filter(query, filters) do
    case Keyword.get(filters, :priority) do
      nil -> query
      priority -> where(query, [t], t.priority == ^priority)
    end
  end
end
```
