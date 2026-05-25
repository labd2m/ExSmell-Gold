```elixir
defmodule AppointmentScheduler do
  @moduledoc """
  Full-stack appointment management: availability, booking, rescheduling,
  conflict checks, time-block management, reminders, reporting, and
  external calendar synchronisation.
  """

  require Logger
  import Ecto.Query
  alias Scheduling.Repo
  alias Scheduling.Appointment
  alias Scheduling.TimeBlock
  alias Scheduling.Provider

  @slot_duration_minutes 30
  @reminder_hours_before 24


  def list_available_slots(provider_id, date) do
    provider = Repo.get!(Provider, provider_id)
    {work_start, work_end} = provider.working_hours

    all_slots =
      Stream.iterate(work_start, fn t -> Time.add(t, @slot_duration_minutes * 60) end)
      |> Enum.take_while(&(Time.compare(&1, work_end) == :lt))
      |> Enum.map(fn start_time ->
        %{
          start: DateTime.new!(date, start_time, "America/Sao_Paulo"),
          end: DateTime.new!(date, Time.add(start_time, @slot_duration_minutes * 60), "America/Sao_Paulo")
        }
      end)

    booked = fetch_booked_ranges(provider_id, date)
    blocked = fetch_blocked_ranges(provider_id, date)

    Enum.reject(all_slots, fn slot ->
      Enum.any?(booked ++ blocked, fn busy ->
        ranges_overlap?(slot.start, slot.end, busy.start, busy.end)
      end)
    end)
  end

  defp fetch_booked_ranges(provider_id, date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "America/Sao_Paulo")
    end_of_day   = DateTime.new!(date, ~T[23:59:59], "America/Sao_Paulo")

    from(a in Appointment,
      where: a.provider_id == ^provider_id and
             a.starts_at >= ^start_of_day and
             a.starts_at <= ^end_of_day and
             a.status != :cancelled,
      select: %{start: a.starts_at, end: a.ends_at}
    )
    |> Repo.all()
  end

  defp fetch_blocked_ranges(provider_id, date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "America/Sao_Paulo")
    end_of_day   = DateTime.new!(date, ~T[23:59:59], "America/Sao_Paulo")

    from(tb in TimeBlock,
      where: tb.provider_id == ^provider_id and
             tb.starts_at >= ^start_of_day and
             tb.ends_at <= ^end_of_day,
      select: %{start: tb.starts_at, end: tb.ends_at}
    )
    |> Repo.all()
  end

  defp ranges_overlap?(s1, e1, s2, e2) do
    DateTime.compare(s1, e2) == :lt and DateTime.compare(e1, s2) == :gt
  end


  def check_conflicts(provider_id, %{starts_at: starts_at, ends_at: ends_at}) do
    existing =
      from(a in Appointment,
        where:
          a.provider_id == ^provider_id and
            a.status != :cancelled and
            a.starts_at < ^ends_at and
            a.ends_at > ^starts_at
      )
      |> Repo.all()

    if Enum.empty?(existing), do: :no_conflict, else: {:conflict, existing}
  end


  def book_appointment(patient_id, provider_id, slot) do
    with :no_conflict <- check_conflicts(provider_id, slot) do
      attrs = %{
        patient_id: patient_id,
        provider_id: provider_id,
        starts_at: slot.starts_at,
        ends_at: slot.ends_at,
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      case Repo.insert(Appointment.changeset(%Appointment{}, attrs)) do
        {:ok, appt} ->
          Logger.info("Appointment #{appt.id} booked for patient #{patient_id}")
          {:ok, appt}

        {:error, cs} ->
          {:error, cs}
      end
    else
      {:conflict, _} -> {:error, :time_slot_unavailable}
    end
  end


  def cancel_appointment(%Appointment{} = appt, reason) do
    appt
    |> Appointment.changeset(%{status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end


  def reschedule_appointment(%Appointment{} = appt, new_slot) do
    with :no_conflict <- check_conflicts(appt.provider_id, new_slot) do
      appt
      |> Appointment.changeset(%{
           starts_at: new_slot.starts_at,
           ends_at: new_slot.ends_at,
           status: :confirmed,
           rescheduled_at: DateTime.utc_now()
         })
      |> Repo.update()
    else
      {:conflict, _} -> {:error, :time_slot_unavailable}
    end
  end


  def block_time_slot(provider_id, starts_at, ends_at) do
    attrs = %{provider_id: provider_id, starts_at: starts_at, ends_at: ends_at}

    case Repo.insert(TimeBlock.changeset(%TimeBlock{}, attrs)) do
      {:ok, tb} ->
        Logger.info("Time block created for provider #{provider_id}: #{starts_at} – #{ends_at}")
        {:ok, tb}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def send_reminder(%Appointment{} = appt) do
    patient = Repo.get!(Scheduling.Patient, appt.patient_id)

    threshold = DateTime.add(DateTime.utc_now(), @reminder_hours_before * 3600, :second)

    if DateTime.compare(appt.starts_at, threshold) == :lt do
      Logger.debug("Skipping reminder for appointment #{appt.id}, it is too soon")
      :skipped
    else
      Mailer.deliver(%{
        to: patient.email,
        subject: "Appointment Reminder",
        text_body: "You have an appointment on #{appt.starts_at}. Please arrive 10 minutes early."
      })

      :ok
    end
  end


  def generate_schedule_report(provider_id, date_range) do
    appointments =
      from(a in Appointment,
        where:
          a.provider_id == ^provider_id and
            a.starts_at >= ^date_range.from and
            a.starts_at <= ^date_range.to,
        order_by: [asc: a.starts_at]
      )
      |> Repo.all()

    total = length(appointments)
    completed = Enum.count(appointments, &(&1.status == :completed))
    cancelled = Enum.count(appointments, &(&1.status == :cancelled))

    %{
      provider_id: provider_id,
      period: date_range,
      total_appointments: total,
      completed: completed,
      cancelled: cancelled,
      utilization_rate: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0)
    }
  end


  def sync_to_calendar(provider_id, calendar_token) do
    today = Date.utc_today()
    slots = list_available_slots(provider_id, today)

    Enum.each(slots, fn slot ->
      GoogleCalendar.create_event(calendar_token, %{
        summary: "Available",
        start: slot.start,
        end: slot.end
      })
    end)

    Logger.info("Synced #{length(slots)} slots to Google Calendar for provider #{provider_id}")
    :ok
  end
end
```
