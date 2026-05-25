# Annotated Example — Large Module (Large Class)

| Field | Value |
|---|---|
| **Smell name** | Large Module (Large Class) |
| **Expected smell location** | `AppointmentScheduler` module (entire module) |
| **Affected functions** | All functions: booking, availability calculation, reminders, cancellation policy, and waitlisting |
| **Short explanation** | `AppointmentScheduler` manages appointment booking, resource availability checking, reminder dispatch, cancellation/refund policy, and waitlist management — five distinct scheduling sub-domains in one module. |

```elixir
# VALIDATION: SMELL START - Large Module (Large Class)
# VALIDATION: This is a smell because AppointmentScheduler conflates booking
# logic, availability computation, reminder dispatch, cancellation policy
# enforcement, and waitlist management — all distinct scheduling concerns —
# into a single non-cohesive module.
defmodule AppointmentScheduler do
  @moduledoc """
  Manages appointment lifecycle including booking, reminders, and waitlists.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Scheduling.{Appointment, AvailabilitySlot, WaitlistEntry, AppointmentReminder}
  alias MyApp.Accounts.User
  alias MyApp.Mailer

  @cancellation_fee_hours 24
  @cancellation_fee_percent 0.50
  @reminder_intervals_hours [48, 2]
  @slot_duration_minutes 60

  # --- Booking ---

  def book(user_id, provider_id, start_dt, service_type) do
    with :ok <- validate_slot_available(provider_id, start_dt),
         {:ok, appt} <-
           Repo.insert(%Appointment{
             user_id: user_id,
             provider_id: provider_id,
             start_at: start_dt,
             end_at: DateTime.add(start_dt, @slot_duration_minutes * 60, :second),
             service_type: service_type,
             status: :confirmed
           }),
         :ok <- block_slot(provider_id, start_dt),
         :ok <- schedule_reminders(appt) do
      Logger.info("Appointment #{appt.id} booked for user #{user_id}")
      {:ok, appt}
    end
  end

  defp validate_slot_available(provider_id, start_dt) do
    conflict =
      Repo.exists?(
        from a in Appointment,
          where:
            a.provider_id == ^provider_id and
              a.status in [:confirmed, :pending] and
              a.start_at == ^start_dt
      )

    if conflict, do: {:error, :slot_not_available}, else: :ok
  end

  defp block_slot(provider_id, start_dt) do
    %AvailabilitySlot{provider_id: provider_id, start_at: start_dt, blocked: true}
    |> Repo.insert(on_conflict: :replace_all, conflict_target: [:provider_id, :start_at])
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  # --- Availability ---

  def available_slots(provider_id, date) do
    start_of_day = DateTime.new!(date, ~T[08:00:00], "Etc/UTC")
    end_of_day = DateTime.new!(date, ~T[18:00:00], "Etc/UTC")

    all_slots = generate_slots(start_of_day, end_of_day)
    blocked = fetch_blocked_slots(provider_id, date)

    Enum.reject(all_slots, fn slot -> MapSet.member?(blocked, slot) end)
  end

  defp generate_slots(from_dt, to_dt) do
    Stream.iterate(from_dt, &DateTime.add(&1, @slot_duration_minutes * 60, :second))
    |> Stream.take_while(&(DateTime.compare(&1, to_dt) == :lt))
    |> Enum.to_list()
  end

  defp fetch_blocked_slots(provider_id, date) do
    Repo.all(
      from s in AvailabilitySlot,
        where: s.provider_id == ^provider_id and s.blocked == true,
        where: fragment("DATE(?)", s.start_at) == ^date,
        select: s.start_at
    )
    |> MapSet.new()
  end

  # --- Reminders ---

  defp schedule_reminders(%Appointment{id: appt_id, start_at: start_at, user_id: user_id}) do
    Enum.each(@reminder_intervals_hours, fn hours ->
      send_at = DateTime.add(start_at, -hours * 3600, :second)

      if DateTime.compare(send_at, DateTime.utc_now()) == :gt do
        Repo.insert(%AppointmentReminder{
          appointment_id: appt_id,
          user_id: user_id,
          send_at: send_at,
          channel: :email,
          status: :pending
        })
      end
    end)

    :ok
  end

  def dispatch_due_reminders do
    now = DateTime.utc_now()

    due =
      Repo.all(
        from r in AppointmentReminder,
          where: r.status == :pending and r.send_at <= ^now,
          preload: [:appointment]
      )

    Enum.each(due, fn reminder ->
      user = Repo.get!(User, reminder.user_id)

      Mailer.send(%{
        to: user.email,
        subject: "Reminder: Your appointment",
        body:
          "Your appointment is at #{DateTime.to_string(reminder.appointment.start_at)}. See you soon!"
      })

      reminder
      |> AppointmentReminder.changeset(%{status: :sent, sent_at: now})
      |> Repo.update()
    end)
  end

  # --- Cancellation Policy ---

  def cancel(appointment_id, cancelled_by) do
    appt = Repo.get!(Appointment, appointment_id)
    hours_until = DateTime.diff(appt.start_at, DateTime.utc_now(), :second) / 3600

    fee = calculate_cancellation_fee(appt, hours_until)

    appt
    |> Appointment.changeset(%{
      status: :cancelled,
      cancelled_at: DateTime.utc_now(),
      cancelled_by: cancelled_by,
      cancellation_fee: fee
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        unblock_slot(appt.provider_id, appt.start_at)
        promote_from_waitlist(appt.provider_id, appt.start_at)
        {:ok, updated, fee}

      err ->
        err
    end
  end

  defp calculate_cancellation_fee(%Appointment{total_price: price}, hours)
       when hours < @cancellation_fee_hours do
    Decimal.mult(price, Decimal.from_float(@cancellation_fee_percent))
  end

  defp calculate_cancellation_fee(_, _), do: Decimal.new(0)

  defp unblock_slot(provider_id, start_at) do
    case Repo.get_by(AvailabilitySlot, provider_id: provider_id, start_at: start_at) do
      nil -> :ok
      slot -> slot |> AvailabilitySlot.changeset(%{blocked: false}) |> Repo.update()
    end
  end

  # --- Waitlist ---

  def join_waitlist(user_id, provider_id, preferred_date) do
    Repo.insert(%WaitlistEntry{
      user_id: user_id,
      provider_id: provider_id,
      preferred_date: preferred_date,
      joined_at: DateTime.utc_now()
    })
  end

  defp promote_from_waitlist(provider_id, freed_slot_dt) do
    date = DateTime.to_date(freed_slot_dt)

    case Repo.one(
           from w in WaitlistEntry,
             where: w.provider_id == ^provider_id and w.preferred_date == ^date,
             order_by: [asc: w.joined_at],
             limit: 1
         ) do
      nil ->
        :ok

      entry ->
        user = Repo.get!(User, entry.user_id)

        Mailer.send(%{
          to: user.email,
          subject: "A slot is available!",
          body: "A slot opened up on #{Date.to_string(date)}. Book now!"
        })

        Repo.delete(entry)
    end
  end

  def waitlist_position(user_id, provider_id, preferred_date) do
    Repo.one(
      from w in WaitlistEntry,
        where:
          w.provider_id == ^provider_id and
            w.preferred_date == ^preferred_date,
        order_by: [asc: w.joined_at],
        select: fragment("ROW_NUMBER() OVER (ORDER BY joined_at)")
    )
  end
end
# VALIDATION: SMELL END
```
