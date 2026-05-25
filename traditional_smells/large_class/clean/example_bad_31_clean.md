```elixir
defmodule EventManager do
  @moduledoc """
  Manages the full lifecycle of events from creation to post-event reporting.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Events.{
    Event,
    TicketType,
    Ticket,
    Attendee,
    CheckIn,
    Sponsor,
    EventSponsor,
    PostEventReport
  }
  alias MyApp.Mailer
  alias MyApp.Accounts.User

  @max_tickets_per_order 10
  @check_in_window_minutes 30


  def create_event(attrs) do
    with {:ok, event} <-
           %Event{}
           |> Event.changeset(attrs)
           |> Repo.insert() do
      Logger.info("Event #{event.id} created: #{event.title}")
      {:ok, event}
    end
  end

  def publish_event(event_id) do
    event = Repo.get!(Event, event_id)

    with :ok <- validate_event_ready(event) do
      event
      |> Event.changeset(%{status: :published, published_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  defp validate_event_ready(%Event{ticket_types: []}), do: {:error, :no_ticket_types}
  defp validate_event_ready(%Event{starts_at: nil}), do: {:error, :missing_start_time}
  defp validate_event_ready(_), do: :ok

  def cancel_event(event_id, reason) do
    event = Repo.get!(Event, event_id)

    with {:ok, cancelled} <-
           event
           |> Event.changeset(%{status: :cancelled, cancellation_reason: reason})
           |> Repo.update() do
      notify_all_attendees(event, reason)
      {:ok, cancelled}
    end
  end

  defp notify_all_attendees(%Event{id: event_id, title: title}, reason) do
    attendees = Repo.all(from a in Attendee, where: a.event_id == ^event_id)

    Enum.each(attendees, fn attendee ->
      Mailer.send(%{
        to: attendee.email,
        subject: "Event Cancelled: #{title}",
        body: "We regret to inform you that #{title} has been cancelled. Reason: #{reason}"
      })
    end)
  end


  def add_ticket_type(event_id, attrs) do
    %TicketType{event_id: event_id}
    |> TicketType.changeset(attrs)
    |> Repo.insert()
  end

  def purchase_tickets(user_id, event_id, ticket_type_id, quantity) do
    with :ok <- validate_quantity(quantity),
         ticket_type <- Repo.get!(TicketType, ticket_type_id),
         :ok <- check_availability(ticket_type, quantity) do
      tickets =
        Enum.map(1..quantity, fn _ ->
          %Ticket{
            event_id: event_id,
            ticket_type_id: ticket_type_id,
            user_id: user_id,
            code: generate_ticket_code(),
            status: :active,
            purchased_at: DateTime.utc_now()
          }
        end)

      {count, inserted} = Repo.insert_all(Ticket, Enum.map(tickets, &Map.from_struct/1), returning: true)

      decrement_availability(ticket_type, quantity)
      user = Repo.get!(User, user_id)
      send_ticket_confirmation(user, event_id, inserted)

      Logger.info("#{count} tickets purchased for event #{event_id} by user #{user_id}")
      {:ok, inserted}
    end
  end

  defp validate_quantity(qty) when qty < 1 or qty > @max_tickets_per_order,
    do: {:error, :invalid_quantity}
  defp validate_quantity(_), do: :ok

  defp check_availability(%TicketType{available: avail}, qty) when avail >= qty, do: :ok
  defp check_availability(_, _), do: {:error, :insufficient_availability}

  defp decrement_availability(%TicketType{} = tt, qty) do
    tt |> TicketType.changeset(%{available: tt.available - qty}) |> Repo.update()
  end

  defp generate_ticket_code do
    :crypto.strong_rand_bytes(6) |> Base.encode16()
  end

  defp send_ticket_confirmation(user, event_id, tickets) do
    event = Repo.get!(Event, event_id)
    codes = tickets |> Enum.map(& &1.code) |> Enum.join(", ")

    Mailer.send(%{
      to: user.email,
      subject: "Your tickets for #{event.title}",
      body: "Your ticket codes: #{codes}. See you there!"
    })
  end


  def check_in(ticket_code, event_id) do
    ticket = Repo.get_by!(Ticket, code: ticket_code, event_id: event_id)
    event = Repo.get!(Event, event_id)
    now = DateTime.utc_now()

    with :ok <- validate_check_in_window(event, now),
         :ok <- validate_ticket_status(ticket) do
      {:ok, check_in} =
        Repo.insert(%CheckIn{
          ticket_id: ticket.id,
          event_id: event_id,
          checked_in_at: now
        })

      ticket |> Ticket.changeset(%{status: :used}) |> Repo.update()
      {:ok, check_in}
    end
  end

  defp validate_check_in_window(%Event{starts_at: starts_at}, now) do
    window_open = DateTime.add(starts_at, -@check_in_window_minutes * 60, :second)

    if DateTime.compare(now, window_open) != :lt, do: :ok, else: {:error, :check_in_not_open}
  end

  defp validate_ticket_status(%Ticket{status: :active}), do: :ok
  defp validate_ticket_status(%Ticket{status: :used}), do: {:error, :ticket_already_used}
  defp validate_ticket_status(%Ticket{status: :refunded}), do: {:error, :ticket_refunded}

  def check_in_stats(event_id) do
    total = Repo.aggregate(from(t in Ticket, where: t.event_id == ^event_id), :count)
    checked_in = Repo.aggregate(from(t in Ticket, where: t.event_id == ^event_id and t.status == :used), :count)
    %{total: total, checked_in: checked_in, remaining: total - checked_in}
  end


  def add_sponsor(event_id, sponsor_attrs, sponsorship_tier) do
    with {:ok, sponsor} <- Repo.insert(Sponsor.changeset(%Sponsor{}, sponsor_attrs)),
         {:ok, event_sponsor} <-
           Repo.insert(%EventSponsor{
             event_id: event_id,
             sponsor_id: sponsor.id,
             tier: sponsorship_tier,
             added_at: DateTime.utc_now()
           }) do
      {:ok, %{sponsor: sponsor, event_sponsor: event_sponsor}}
    end
  end

  def list_sponsors(event_id) do
    Repo.all(
      from es in EventSponsor,
        join: s in Sponsor,
        on: es.sponsor_id == s.id,
        where: es.event_id == ^event_id,
        order_by: [asc: es.tier],
        select: %{name: s.name, logo_url: s.logo_url, tier: es.tier, website: s.website}
    )
  end


  def generate_post_event_report(event_id) do
    event = Repo.get!(Event, event_id)
    stats = check_in_stats(event_id)
    sponsors = list_sponsors(event_id)

    revenue =
      Repo.one(
        from t in Ticket,
          join: tt in TicketType,
          on: t.ticket_type_id == tt.id,
          where: t.event_id == ^event_id,
          select: coalesce(sum(tt.price), 0)
      )

    report = %{
      event_id: event.id,
      event_title: event.title,
      total_tickets_sold: stats.total,
      attendance_count: stats.checked_in,
      attendance_rate: if(stats.total > 0, do: Float.round(stats.checked_in / stats.total * 100, 1), else: 0.0),
      total_revenue: revenue,
      sponsor_count: length(sponsors),
      generated_at: DateTime.utc_now()
    }

    Repo.insert(%PostEventReport{
      event_id: event_id,
      data: report,
      generated_at: DateTime.utc_now()
    })
    |> case do
      {:ok, saved} ->
        Logger.info("Post-event report generated for event #{event_id}")
        {:ok, Map.put(report, :id, saved.id)}

      err ->
        err
    end
  end
end
```
