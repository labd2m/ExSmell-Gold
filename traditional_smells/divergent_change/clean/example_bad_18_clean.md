```elixir
defmodule Events.EventHub do
  @moduledoc """
  Manages event lifecycle, attendee registration, and ticket validation.
  """

  alias Events.Repo
  alias Events.Events.Event
  alias Events.Registrations.Registration
  alias Events.Tickets.Ticket

  import Ecto.Query
  require Logger



  @doc "Creates a new event in draft state."
  @spec create_event(String.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_event(organiser_id, attrs) do
    %Event{}
    |> Event.changeset(Map.merge(attrs, %{organiser_id: organiser_id, status: :draft}))
    |> Repo.insert()
  end

  @doc "Publishes an event so it accepts registrations."
  @spec publish_event(Event.t()) :: {:ok, Event.t()} | {:error, atom()}
  def publish_event(%Event{status: :draft} = event) do
    if event_ready_to_publish?(event) do
      event
      |> Event.changeset(%{status: :published, published_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :incomplete_event}
    end
  end

  def publish_event(%Event{}), do: {:error, :not_draft}

  @doc "Cancels a published event and notifies registered attendees."
  @spec cancel_event(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, atom()}
  def cancel_event(%Event{status: :published, id: event_id} = event, reason) do
    Repo.transaction(fn ->
      {:ok, cancelled} =
        event
        |> Event.changeset(%{status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()})
        |> Repo.update()

      Registration
      |> where([r], r.event_id == ^event_id and r.status == :confirmed)
      |> Repo.update_all(set: [status: :cancelled_by_organiser])

      Logger.info("Event #{event_id} cancelled. All registrations voided.")
      cancelled
    end)
  end

  def cancel_event(%Event{}, _), do: {:error, :not_published}


  @doc "Registers an attendee for an event."
  @spec register_attendee(Event.t(), map()) ::
          {:ok, Registration.t()} | {:error, atom()}
  def register_attendee(%Event{status: :published, id: event_id, capacity: cap} = event, params) do
    confirmed_count =
      Registration
      |> where([r], r.event_id == ^event_id and r.status == :confirmed)
      |> Repo.aggregate(:count, :id)

    cond do
      confirmed_count >= cap ->
        add_to_waitlist(event, params)

      already_registered?(event_id, params[:attendee_id]) ->
        {:error, :already_registered}

      true ->
        attrs = %{
          event_id: event_id,
          attendee_id: params[:attendee_id],
          ticket_type: params[:ticket_type] || :general,
          status: :confirmed,
          registered_at: DateTime.utc_now()
        }

        %Registration{} |> Registration.changeset(attrs) |> Repo.insert()
    end
  end

  def register_attendee(%Event{}, _), do: {:error, :registration_closed}

  @doc "Cancels an attendee's registration and promotes the first waitlisted person."
  @spec cancel_registration(Registration.t(), String.t()) ::
          {:ok, Registration.t()} | {:error, atom()}
  def cancel_registration(%Registration{status: :confirmed} = reg, reason) do
    Repo.transaction(fn ->
      {:ok, cancelled} =
        reg
        |> Registration.changeset(%{status: :cancelled, cancellation_reason: reason})
        |> Repo.update()

      promote_from_waitlist(reg.event_id)
      cancelled
    end)
  end

  def cancel_registration(%Registration{}, _), do: {:error, :not_confirmed}

  @doc "Lists all confirmed registrations for an event."
  @spec list_registrations(Event.t()) :: [Registration.t()]
  def list_registrations(%Event{id: event_id}) do
    Registration
    |> where([r], r.event_id == ^event_id and r.status == :confirmed)
    |> order_by([r], asc: r.registered_at)
    |> Repo.all()
  end


  @doc "Generates a signed ticket for a confirmed registration."
  @spec generate_ticket(Registration.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def generate_ticket(%Registration{status: :confirmed, id: reg_id, event_id: event_id}) do
    token =
      Phoenix.Token.sign(
        EventsWeb.Endpoint,
        "ticket",
        %{registration_id: reg_id, event_id: event_id}
      )

    attrs = %{
      registration_id: reg_id,
      event_id: event_id,
      token: token,
      qr_data: Base.encode64(token),
      issued_at: DateTime.utc_now(),
      status: :valid
    }

    %Ticket{} |> Ticket.changeset(attrs) |> Repo.insert()
  end

  def generate_ticket(%Registration{}), do: {:error, :registration_not_confirmed}

  @doc "Validates a ticket token without consuming it."
  @spec validate_ticket(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_ticket(token) do
    case Phoenix.Token.verify(EventsWeb.Endpoint, "ticket", token, max_age: 86_400 * 365) do
      {:ok, claims} ->
        ticket = Repo.get_by(Ticket, token: token)

        cond do
          is_nil(ticket) -> {:error, :ticket_not_found}
          ticket.status == :used -> {:error, :already_used}
          ticket.status == :revoked -> {:error, :ticket_revoked}
          true -> {:ok, claims}
        end

      {:error, _} ->
        {:error, :invalid_token}
    end
  end

  @doc "Checks in an attendee by consuming their ticket."
  @spec check_in_attendee(String.t(), String.t()) :: {:ok, Ticket.t()} | {:error, atom()}
  def check_in_attendee(token, staff_id) do
    with {:ok, _claims} <- validate_ticket(token) do
      ticket = Repo.get_by!(Ticket, token: token)

      ticket
      |> Ticket.changeset(%{
        status: :used,
        checked_in_by: staff_id,
        checked_in_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end


  defp event_ready_to_publish?(%Event{title: t, starts_at: s, location: l})
       when is_binary(t) and not is_nil(s) and is_binary(l),
       do: true

  defp event_ready_to_publish?(_), do: false

  defp already_registered?(event_id, attendee_id) do
    Registration
    |> where(
      [r],
      r.event_id == ^event_id and r.attendee_id == ^attendee_id and r.status != :cancelled
    )
    |> Repo.exists?()
  end

  defp add_to_waitlist(%Event{id: event_id}, params) do
    attrs = %{
      event_id: event_id,
      attendee_id: params[:attendee_id],
      ticket_type: params[:ticket_type] || :general,
      status: :waitlisted,
      registered_at: DateTime.utc_now()
    }

    %Registration{} |> Registration.changeset(attrs) |> Repo.insert()
  end

  defp promote_from_waitlist(event_id) do
    next =
      Registration
      |> where([r], r.event_id == ^event_id and r.status == :waitlisted)
      |> order_by([r], asc: r.registered_at)
      |> limit(1)
      |> Repo.one()

    if next do
      next |> Registration.changeset(%{status: :confirmed}) |> Repo.update!()
      Logger.info("Promoted waitlisted attendee #{next.attendee_id} to confirmed")
    end
  end

end
```
