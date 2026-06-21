```elixir
defmodule Support.TicketFSM do
  @moduledoc """
  Models a customer support ticket's state machine as a pure functional
  module. All transitions are explicit pattern-matched functions rather
  than a generic dispatcher, making illegal state changes a compile-time
  concern when called correctly, and a clear runtime error otherwise.
  No process is involved; the ticket struct is threaded through callers.
  """

  @enforce_keys [:id, :subject, :status, :requester_id]
  defstruct [:id, :subject, :body, :status, :requester_id, :assignee_id,
             :resolved_at, :closed_at, events: []]

  @type status :: :open | :pending | :on_hold | :resolved | :closed
  @type t :: %__MODULE__{
          id: String.t(),
          subject: String.t(),
          body: String.t() | nil,
          status: status(),
          requester_id: String.t(),
          assignee_id: String.t() | nil,
          resolved_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil,
          events: [map()]
        }

  @type transition_error :: {:error, :invalid_transition}

  @doc "Creates a new ticket in the `:open` state."
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(id, subject, requester_id)
      when is_binary(id) and is_binary(subject) and is_binary(requester_id) do
    ticket = %__MODULE__{id: id, subject: subject, status: :open, requester_id: requester_id}
    record_event(ticket, :opened, %{})
  end

  @doc "Assigns the ticket to an agent, transitioning from `:open` to `:pending`."
  @spec assign(t(), String.t()) :: {:ok, t()} | transition_error()
  def assign(%__MODULE__{status: :open} = ticket, agent_id) when is_binary(agent_id) do
    {:ok, ticket |> Map.put(:assignee_id, agent_id) |> put_status(:pending) |> record_event(:assigned, %{agent_id: agent_id})}
  end

  def assign(%__MODULE__{}, _agent_id), do: {:error, :invalid_transition}

  @doc "Places a `:pending` ticket on hold awaiting customer response."
  @spec hold(t()) :: {:ok, t()} | transition_error()
  def hold(%__MODULE__{status: :pending} = ticket) do
    {:ok, ticket |> put_status(:on_hold) |> record_event(:held, %{})}
  end

  def hold(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc "Resumes a ticket that was on hold, returning it to `:pending`."
  @spec resume(t()) :: {:ok, t()} | transition_error()
  def resume(%__MODULE__{status: :on_hold} = ticket) do
    {:ok, ticket |> put_status(:pending) |> record_event(:resumed, %{})}
  end

  def resume(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc "Marks a `:pending` ticket as resolved."
  @spec resolve(t()) :: {:ok, t()} | transition_error()
  def resolve(%__MODULE__{status: :pending} = ticket) do
    resolved_at = DateTime.utc_now()
    {:ok, ticket |> Map.put(:resolved_at, resolved_at) |> put_status(:resolved) |> record_event(:resolved, %{})}
  end

  def resolve(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc "Closes a resolved ticket permanently."
  @spec close(t()) :: {:ok, t()} | transition_error()
  def close(%__MODULE__{status: :resolved} = ticket) do
    closed_at = DateTime.utc_now()
    {:ok, ticket |> Map.put(:closed_at, closed_at) |> put_status(:closed) |> record_event(:closed, %{})}
  end

  def close(%__MODULE__{}), do: {:error, :invalid_transition}

  defp put_status(ticket, status), do: %{ticket | status: status}

  defp record_event(ticket, name, meta) do
    event = Map.merge(%{name: name, occurred_at: DateTime.utc_now()}, meta)
    %{ticket | events: ticket.events ++ [event]}
  end
end
```
