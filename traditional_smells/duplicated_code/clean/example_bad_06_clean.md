```elixir
defmodule Scheduling.AppointmentManager do
  @moduledoc """
  Manages appointment booking, rescheduling, and cancellation
  for a multi-provider scheduling platform.
  """

  alias Scheduling.Repo
  alias Scheduling.Appointment
  alias Scheduling.Provider
  alias Scheduling.Patient

  @slot_duration_minutes 30

  @doc """
  Books a new appointment for a patient with a specific provider.
  `start_time` is a `DateTime` in UTC.
  """
  def book(%Patient{} = patient, %Provider{} = provider, start_time) do
    end_time = DateTime.add(start_time, @slot_duration_minutes * 60, :second)

    existing = Repo.all_by(Appointment, provider_id: provider.id, status: :confirmed)

    conflict =
      Enum.any?(existing, fn appt ->
        DateTime.compare(appt.start_time, end_time) == :lt and
          DateTime.compare(appt.end_time, start_time) == :gt
      end)

    if conflict do
      {:error, :slot_unavailable}
    else
      appt = %Appointment{
        patient_id: patient.id,
        provider_id: provider.id,
        start_time: start_time,
        end_time: end_time,
        status: :confirmed
      }

      Repo.insert(appt)
    end
  end

  @doc """
  Reschedules an existing appointment to a new start time.
  Validates slot availability before applying the change.
  """
  def reschedule(%Appointment{} = appt, %Provider{} = provider, new_start_time) do
    new_end_time = DateTime.add(new_start_time, @slot_duration_minutes * 60, :second)

    existing =
      Repo.all_by(Appointment, provider_id: provider.id, status: :confirmed)
      |> Enum.reject(&(&1.id == appt.id))

    conflict =
      Enum.any?(existing, fn existing_appt ->
        DateTime.compare(existing_appt.start_time, new_end_time) == :lt and
          DateTime.compare(existing_appt.end_time, new_start_time) == :gt
      end)

    if conflict do
      {:error, :slot_unavailable}
    else
      updated = %{appt | start_time: new_start_time, end_time: new_end_time, rescheduled: true}
      Repo.update(updated)
    end
  end

  @doc """
  Cancels an appointment and marks it as cancelled in the database.
  """
  def cancel(%Appointment{} = appt, reason \\ nil) do
    updated = %{appt | status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()}
    Repo.update(updated)
  end

  @doc """
  Lists all upcoming confirmed appointments for a provider.
  """
  def upcoming_for_provider(%Provider{} = provider) do
    now = DateTime.utc_now()

    Repo.all_by(Appointment, provider_id: provider.id, status: :confirmed)
    |> Enum.filter(fn appt -> DateTime.compare(appt.start_time, now) == :gt end)
    |> Enum.sort_by(& &1.start_time, DateTime)
  end
end
```
