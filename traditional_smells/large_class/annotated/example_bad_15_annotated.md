# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `SchedulingManager` module
- **Affected function(s):** `create_appointment/3`, `reschedule_appointment/2`, `cancel_appointment/2`, `check_availability/3`, `block_slot/3`, `release_block/1`, `send_reminder/2`, `mark_no_show/1`, `complete_appointment/2`, `generate_availability_calendar/2`, `appointment_report/2`
- **Short explanation:** `SchedulingManager` handles appointment creation and rescheduling, slot availability checking, manual slot blocking, automated reminders, no-show recording, appointment completion, calendar generation, and reporting. These are distinct scheduling sub-concerns that belong in separate modules like `AppointmentLifecycle`, `AvailabilityEngine`, `ReminderService`, `CalendarRenderer`, and `SchedulingReports`.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because SchedulingManager conflates appointment
# lifecycle (create, reschedule, cancel, complete, no-show), slot availability
# and blocking, reminder delivery, calendar generation, and reporting — five
# distinct scheduling concerns that should be split into focused modules.
defmodule MyApp.SchedulingManager do
  @moduledoc """
  Manages appointments, availability windows, slot blocking,
  reminders, no-shows, and scheduling analytics.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Scheduling.{Appointment, AvailabilityBlock, SlotBlock, ReminderLog}
  alias MyApp.Accounts.User

  @slot_duration_minutes 30
  @reminder_hours_before [24, 2]
  @business_hours %{start: 8, end: 18}

  # -------------------------------------------------------------------
  # Appointment lifecycle
  # -------------------------------------------------------------------

  def create_appointment(%User{} = client, provider_id, starts_at) do
    case check_availability(provider_id, starts_at, @slot_duration_minutes) do
      {:error, _} = err ->
        err

      :available ->
        ends_at = DateTime.add(starts_at, @slot_duration_minutes * 60, :second)

        appointment = Repo.insert!(%Appointment{
          client_id:   client.id,
          provider_id: provider_id,
          starts_at:   starts_at,
          ends_at:     ends_at,
          status:      :scheduled
        })

        schedule_reminders(appointment)
        notify_appointment_created(appointment)
        {:ok, appointment}
    end
  end

  def reschedule_appointment(%Appointment{status: :scheduled} = apt, new_starts_at) do
    case check_availability(apt.provider_id, new_starts_at, @slot_duration_minutes) do
      {:error, _} = err ->
        err

      :available ->
        new_ends_at = DateTime.add(new_starts_at, @slot_duration_minutes * 60, :second)

        updated = Repo.update!(Appointment.changeset(apt, %{
          starts_at:      new_starts_at,
          ends_at:        new_ends_at,
          rescheduled_at: DateTime.utc_now()
        }))

        cancel_pending_reminders(apt.id)
        schedule_reminders(updated)
        notify_appointment_rescheduled(updated)
        {:ok, updated}
    end
  end

  def reschedule_appointment(%Appointment{status: s}, _),
    do: {:error, "Cannot reschedule appointment in status #{s}"}

  def cancel_appointment(%Appointment{status: s} = apt, reason)
      when s in [:scheduled, :confirmed] do
    Repo.update!(Appointment.changeset(apt, %{
      status:        :canceled,
      canceled_at:   DateTime.utc_now(),
      cancel_reason: reason
    }))

    cancel_pending_reminders(apt.id)

    client = Repo.get!(User, apt.client_id)
    MyApp.Mailer.deliver(%{
      to:      client.email,
      subject: "Appointment canceled",
      body:    "Your appointment on #{apt.starts_at} has been canceled. Reason: #{reason}."
    })

    :ok
  end

  def cancel_appointment(%Appointment{status: s}, _),
    do: {:error, "Cannot cancel appointment in status #{s}"}

  def complete_appointment(%Appointment{status: s} = apt, notes)
      when s in [:scheduled, :confirmed] do
    Repo.update!(Appointment.changeset(apt, %{
      status:        :completed,
      completed_at:  DateTime.utc_now(),
      provider_notes: notes
    }))

    :ok
  end

  def complete_appointment(%Appointment{status: s}, _),
    do: {:error, "Cannot complete appointment in status #{s}"}

  def mark_no_show(%Appointment{status: :scheduled} = apt) do
    Repo.update!(Appointment.changeset(apt, %{
      status:      :no_show,
      no_show_at:  DateTime.utc_now()
    }))

    Logger.warning("No-show recorded for appointment #{apt.id}")
    :ok
  end

  def mark_no_show(%Appointment{status: s}),
    do: {:error, "Cannot mark no-show for appointment in status #{s}"}

  # -------------------------------------------------------------------
  # Availability checking
  # -------------------------------------------------------------------

  def check_availability(provider_id, starts_at, duration_minutes) do
    ends_at = DateTime.add(starts_at, duration_minutes * 60, :second)
    hour    = starts_at.hour

    cond do
      hour < @business_hours.start or hour >= @business_hours.end ->
        {:error, :outside_business_hours}

      slot_blocked?(provider_id, starts_at, ends_at) ->
        {:error, :slot_blocked}

      appointment_conflict?(provider_id, starts_at, ends_at) ->
        {:error, :conflict}

      true ->
        :available
    end
  end

  defp slot_blocked?(provider_id, starts_at, ends_at) do
    Repo.exists?(from sb in SlotBlock,
      where: sb.provider_id == ^provider_id
        and sb.starts_at < ^ends_at
        and sb.ends_at > ^starts_at)
  end

  defp appointment_conflict?(provider_id, starts_at, ends_at) do
    Repo.exists?(from a in Appointment,
      where: a.provider_id == ^provider_id
        and a.status in [:scheduled, :confirmed]
        and a.starts_at < ^ends_at
        and a.ends_at > ^starts_at)
  end

  # -------------------------------------------------------------------
  # Slot blocking
  # -------------------------------------------------------------------

  def block_slot(provider_id, starts_at, ends_at, reason \\ nil) do
    Repo.insert(%SlotBlock{
      provider_id: provider_id,
      starts_at:   starts_at,
      ends_at:     ends_at,
      reason:      reason
    })
  end

  def release_block(block_id) do
    case Repo.get(SlotBlock, block_id) do
      nil   -> {:error, :not_found}
      block -> Repo.delete!(block); :ok
    end
  end

  # -------------------------------------------------------------------
  # Reminders
  # -------------------------------------------------------------------

  def send_reminder(%Appointment{} = apt, hours_before) do
    client = Repo.get!(User, apt.client_id)

    MyApp.Mailer.deliver(%{
      to:      client.email,
      subject: "Reminder: Appointment in #{hours_before} hour(s)",
      body:    "Don't forget your appointment at #{apt.starts_at}."
    })

    Repo.insert!(%ReminderLog{
      appointment_id: apt.id,
      hours_before:   hours_before,
      sent_at:        DateTime.utc_now()
    })

    :ok
  end

  defp schedule_reminders(%Appointment{} = apt) do
    Enum.each(@reminder_hours_before, fn hours ->
      remind_at = DateTime.add(apt.starts_at, -hours * 3600, :second)
      if DateTime.compare(remind_at, DateTime.utc_now()) == :gt do
        Logger.info("Reminder for apt #{apt.id} scheduled #{hours}h before")
      end
    end)
  end

  defp cancel_pending_reminders(appointment_id) do
    Logger.info("Canceling pending reminders for appointment #{appointment_id}")
  end

  # -------------------------------------------------------------------
  # Calendar generation
  # -------------------------------------------------------------------

  def generate_availability_calendar(provider_id, week_start) do
    week_end = Date.add(week_start, 6)

    slots =
      Enum.flat_map(Date.range(week_start, week_end), fn date ->
        Enum.map(@business_hours.start..(@business_hours.end - 1)//1, fn hour ->
          Enum.map([0, 30], fn minute ->
            {:ok, starts_at, _} = DateTime.from_iso8601("#{date}T#{String.pad_leading("#{hour}", 2, "0")}:#{String.pad_leading("#{minute}", 2, "0")}:00Z")
            ends_at = DateTime.add(starts_at, @slot_duration_minutes * 60, :second)

            available =
              case check_availability(provider_id, starts_at, @slot_duration_minutes) do
                :available       -> true
                {:error, _}      -> false
              end

            %{starts_at: starts_at, ends_at: ends_at, available: available}
          end)
        end)
      end)
      |> List.flatten()

    %{provider_id: provider_id, week_start: week_start, slots: slots}
  end

  # -------------------------------------------------------------------
  # Notifications
  # -------------------------------------------------------------------

  defp notify_appointment_created(%Appointment{} = apt) do
    client = Repo.get!(User, apt.client_id)
    MyApp.Mailer.deliver(%{
      to:      client.email,
      subject: "Appointment confirmed",
      body:    "Your appointment is scheduled for #{apt.starts_at}."
    })
  end

  defp notify_appointment_rescheduled(%Appointment{} = apt) do
    client = Repo.get!(User, apt.client_id)
    MyApp.Mailer.deliver(%{
      to:      client.email,
      subject: "Appointment rescheduled",
      body:    "Your appointment has been moved to #{apt.starts_at}."
    })
  end

  # -------------------------------------------------------------------
  # Reporting
  # -------------------------------------------------------------------

  def appointment_report(provider_id, since) do
    from(a in Appointment,
      where: a.provider_id == ^provider_id and a.starts_at >= ^since
    )
    |> Repo.all()
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, apts} -> {status, length(apts)} end)
  end
end
# VALIDATION: SMELL END
```
