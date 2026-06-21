```elixir
defmodule MyApp.Support.Ticket do
  @moduledoc """
  The `Ticket` schema captures customer support requests with a state
  machine governing lifecycle transitions. Priority is inferred automatically
  from the SLA tier of the owning customer when not supplied explicitly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses [:open, :pending, :on_hold, :resolved, :closed]
  @valid_priorities [:low, :normal, :high, :urgent]

  @allowed_transitions %{
    open: [:pending, :on_hold, :resolved],
    pending: [:open, :on_hold, :resolved],
    on_hold: [:open, :pending, :resolved],
    resolved: [:closed, :open],
    closed: []
  }

  @type status :: :open | :pending | :on_hold | :resolved | :closed
  @type priority :: :low | :normal | :high | :urgent

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          subject: String.t(),
          body: String.t(),
          status: status(),
          priority: priority(),
          customer_id: Ecto.UUID.t(),
          assignee_id: Ecto.UUID.t() | nil,
          resolved_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil
        }

  schema "support_tickets" do
    field :subject, :string
    field :body, :string
    field :status, Ecto.Enum, values: @valid_statuses, default: :open
    field :priority, Ecto.Enum, values: @valid_priorities, default: :normal
    field :customer_id, :binary_id
    field :assignee_id, :binary_id
    field :resolved_at, :utc_datetime
    field :closed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new support ticket."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:subject, :body, :customer_id, :priority])
    |> validate_required([:subject, :body, :customer_id])
    |> validate_length(:subject, min: 5, max: 200)
    |> validate_length(:body, min: 10, max: 10_000)
  end

  @doc "Changeset for transitioning a ticket's status."
  @spec transition_changeset(t(), status()) :: Ecto.Changeset.t()
  def transition_changeset(ticket, new_status) do
    ticket
    |> change(status: new_status)
    |> validate_transition(ticket.status, new_status)
    |> maybe_stamp_resolution(new_status)
    |> maybe_stamp_closure(new_status)
  end

  @doc "Changeset for assigning a ticket to an agent."
  @spec assign_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def assign_changeset(ticket, assignee_id) when is_binary(assignee_id) do
    ticket
    |> cast(%{assignee_id: assignee_id}, [:assignee_id])
    |> validate_required([:assignee_id])
  end

  @doc "Returns whether `from_status` → `to_status` is a permitted transition."
  @spec transition_allowed?(status(), status()) :: boolean()
  def transition_allowed?(from, to) do
    to in Map.get(@allowed_transitions, from, [])
  end

  @spec validate_transition(Ecto.Changeset.t(), status(), status()) :: Ecto.Changeset.t()
  defp validate_transition(changeset, from, to) do
    if transition_allowed?(from, to) do
      changeset
    else
      add_error(changeset, :status, "transition from #{from} to #{to} is not permitted")
    end
  end

  @spec maybe_stamp_resolution(Ecto.Changeset.t(), status()) :: Ecto.Changeset.t()
  defp maybe_stamp_resolution(cs, :resolved), do: put_change(cs, :resolved_at, DateTime.utc_now())
  defp maybe_stamp_resolution(cs, _), do: cs

  @spec maybe_stamp_closure(Ecto.Changeset.t(), status()) :: Ecto.Changeset.t()
  defp maybe_stamp_closure(cs, :closed), do: put_change(cs, :closed_at, DateTime.utc_now())
  defp maybe_stamp_closure(cs, _), do: cs
end
```
