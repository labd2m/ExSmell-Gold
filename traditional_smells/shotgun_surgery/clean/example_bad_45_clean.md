```elixir
defmodule MyApp.Scheduling.BookingEngine do
  @moduledoc """
  Handles appointment booking with type-specific availability and capacity rules.
  Integrates with the calendar store to check slot availability and persist bookings.
  """

  alias MyApp.Scheduling.{DurationPolicy, Calendar, Waitlist}
  alias MyApp.Repo

  require Logger

  def book(%{type: :consultation} = appointment, provider, patient) do
    slots_needed = DurationPolicy.slots_required(:consultation)

    with {:ok, slot} <- Calendar.find_slot(provider.id, appointment.requested_at, slots_needed),
         :ok <- check_patient_eligibility(patient, :consultation),
         {:ok, booking} <- Repo.insert(build_booking(appointment, provider, patient, slot)) do
      Logger.info("Consultation booked", booking_id: booking.id, provider_id: provider.id)
      {:ok, booking}
    else
      {:error, :no_availability} -> {:error, :provider_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  def book(%{type: :follow_up} = appointment, provider, patient) do
    slots_needed = DurationPolicy.slots_required(:follow_up)

    with :ok <- validate_prior_consultation(patient, provider),
         {:ok, slot} <- Calendar.find_slot(provider.id, appointment.requested_at, slots_needed),
         {:ok, booking} <- Repo.insert(build_booking(appointment, provider, patient, slot)) do
      Logger.info("Follow-up booked", booking_id: booking.id, provider_id: provider.id)
      {:ok, booking}
    else
      {:error, :no_prior_consultation} -> {:error, :follow_up_requires_prior_consultation}
      {:error, :no_availability} -> {:error, :provider_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  def book(%{type: :exam} = appointment, provider, patient) do
    slots_needed = DurationPolicy.slots_required(:exam)

    with {:ok, slot} <- Calendar.find_slot(provider.id, appointment.requested_at, slots_needed),
         :ok <- check_equipment_availability(appointment.exam_type, slot),
         {:ok, booking} <- Repo.insert(build_booking(appointment, provider, patient, slot)) do
      Logger.info("Exam booked", booking_id: booking.id, exam_type: appointment.exam_type)
      {:ok, booking}
    else
      {:error, :equipment_unavailable} -> {:error, :exam_equipment_not_available}
      {:error, :no_availability} -> {:error, :provider_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  def book(%{type: unknown}, _provider, _patient) do
    {:error, {:unsupported_appointment_type, unknown}}
  end

  defp check_patient_eligibility(patient, :consultation) do
    if patient.insurance_verified?, do: :ok, else: {:error, :insurance_not_verified}
  end

  defp validate_prior_consultation(patient, provider) do
    if Repo.exists?(prior_consultation_query(patient.id, provider.id)),
       do: :ok,
       else: {:error, :no_prior_consultation}
  end

  defp check_equipment_availability(exam_type, slot) do
    if MyApp.Equipment.available?(exam_type, slot.starts_at), do: :ok, else: {:error, :equipment_unavailable}
  end

  defp prior_consultation_query(patient_id, provider_id) do
    import Ecto.Query
    from b in "bookings", where: b.patient_id == ^patient_id and b.provider_id == ^provider_id and b.type == "consultation"
  end

  defp build_booking(appointment, provider, patient, slot) do
    %MyApp.Scheduling.Booking{
      type: appointment.type,
      provider_id: provider.id,
      patient_id: patient.id,
      starts_at: slot.starts_at,
      ends_at: slot.ends_at,
      status: :confirmed
    }
  end
end

defmodule MyApp.Scheduling.DurationPolicy do
  @moduledoc """
  Defines time-slot requirements for each appointment type.
  Each slot represents a 15-minute block in the provider's calendar grid.
  """

  @consultation_slots 4
  @follow_up_slots 2
  @exam_slots 6

  def slots_required(:consultation), do: @consultation_slots
  def slots_required(:follow_up), do: @follow_up_slots
  def slots_required(:exam), do: @exam_slots
  def slots_required(unknown), do: raise(ArgumentError, "Unknown appointment type: #{inspect(unknown)}")

  def duration_minutes(type) do
    slots_required(type) * 15
  end

  def label(:consultation), do: "Initial Consultation (60 min)"
  def label(:follow_up), do: "Follow-up Visit (30 min)"
  def label(:exam), do: "Clinical Exam (90 min)"
  def label(unknown), do: "Unknown (#{inspect(unknown)})"
end

defmodule MyApp.Scheduling.ReminderService do
  @moduledoc """
  Schedules appointment reminders based on type-specific timing rules.
  Reminders are enqueued as background jobs to be sent via the notification pipeline.
  """

  alias MyApp.Workers.ReminderWorker

  def schedule_reminders(%{type: :consultation} = booking, _opts) do
    jobs = [
      {booking, hours_before: 48, message: :reminder_48h},
      {booking, hours_before: 24, message: :reminder_24h},
      {booking, hours_before: 2, message: :reminder_2h}
    ]

    Enum.each(jobs, fn {b, hours_before: h, message: msg} ->
      run_at = DateTime.add(b.starts_at, -h * 3600, :second)
      ReminderWorker.new(%{booking_id: b.id, message: msg}, scheduled_at: run_at) |> Oban.insert!()
    end)

    :ok
  end

  def schedule_reminders(%{type: :follow_up} = booking, _opts) do
    jobs = [
      {booking, hours_before: 24, message: :reminder_24h},
      {booking, hours_before: 1, message: :reminder_1h}
    ]

    Enum.each(jobs, fn {b, hours_before: h, message: msg} ->
      run_at = DateTime.add(b.starts_at, -h * 3600, :second)
      ReminderWorker.new(%{booking_id: b.id, message: msg}, scheduled_at: run_at) |> Oban.insert!()
    end)

    :ok
  end

  def schedule_reminders(%{type: :exam} = booking, _opts) do
    jobs = [
      {booking, hours_before: 72, message: :preparation_instructions},
      {booking, hours_before: 24, message: :reminder_24h},
      {booking, hours_before: 2, message: :reminder_2h}
    ]

    Enum.each(jobs, fn {b, hours_before: h, message: msg} ->
      run_at = DateTime.add(b.starts_at, -h * 3600, :second)
      ReminderWorker.new(%{booking_id: b.id, message: msg}, scheduled_at: run_at) |> Oban.insert!()
    end)

    :ok
  end

  def schedule_reminders(%{type: unknown}, _opts) do
    {:error, {:unsupported_appointment_type, unknown}}
  end
end
```
