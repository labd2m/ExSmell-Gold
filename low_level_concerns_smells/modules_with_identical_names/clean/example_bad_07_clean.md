```elixir
# ── file: lib/scheduling/appointment.ex ──────────────────────────────────────

defmodule Scheduling.Appointment do
  @moduledoc """
  Core appointment booking module. Creates confirmed time-slot reservations
  for practitioners and clients in the scheduling system.
  """

  alias Scheduling.{Practitioner, Client, TimeSlot, ConflictChecker, Notifier}

  @confirmation_code_length 8
  @default_duration_minutes 60

  @type t :: %__MODULE__{
          id: String.t(),
          practitioner_id: String.t(),
          client_id: String.t(),
          slot: TimeSlot.t(),
          duration_minutes: pos_integer(),
          service_type: atom(),
          confirmation_code: String.t(),
          status: :pending | :confirmed | :cancelled | :completed | :no_show,
          notes: String.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :practitioner_id,
    :client_id,
    :slot,
    :confirmation_code,
    :notes,
    :created_at,
    duration_minutes: @default_duration_minutes,
    service_type: :general,
    status: :pending
  ]

  @spec book(Practitioner.t(), map()) :: {:ok, t()} | {:error, term()}
  def book(%Practitioner{} = practitioner, attrs) do
    client_id = Map.fetch!(attrs, :client_id)
    slot = Map.fetch!(attrs, :slot)
    service_type = Map.get(attrs, :service_type, :general)
    duration = Map.get(attrs, :duration_minutes, @default_duration_minutes)

    with {:ok, client} <- Client.fetch(client_id),
         :ok <- ConflictChecker.check_practitioner(practitioner.id, slot, duration),
         :ok <- ConflictChecker.check_client(client.id, slot, duration),
         :ok <- validate_service_eligibility(practitioner, service_type) do
      appointment = %__MODULE__{
        id: generate_id(),
        practitioner_id: practitioner.id,
        client_id: client.id,
        slot: slot,
        duration_minutes: duration,
        service_type: service_type,
        confirmation_code: generate_confirmation_code(),
        status: :confirmed,
        notes: Map.get(attrs, :notes),
        created_at: DateTime.utc_now()
      }

      Notifier.send_confirmation(appointment)

      {:ok, appointment}
    end
  end

  @spec cancel(t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def cancel(%__MODULE__{status: status} = appt, opts \\ []) when status in [:pending, :confirmed] do
    reason = Keyword.get(opts, :reason, "No reason provided")
    Notifier.send_cancellation(appt, reason)
    {:ok, %{appt | status: :cancelled}}
  end

  def cancel(_, _), do: {:error, "appointment cannot be cancelled in its current state"}

  defp validate_service_eligibility(%Practitioner{services: services}, service_type) do
    if service_type in services, do: :ok, else: {:error, :service_not_offered}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp generate_confirmation_code do
    :crypto.strong_rand_bytes(@confirmation_code_length)
    |> Base.encode32(case: :upper, padding: false)
    |> String.slice(0, @confirmation_code_length)
  end
end


# ── file: lib/scheduling/appointment_management.ex ───────────────────────────

defmodule Scheduling.Appointment do
  @moduledoc """
  Handles lifecycle management of existing appointments: rescheduling,
  status transitions, and practitioner-side updates.
  """

  alias Scheduling.{ConflictChecker, Notifier, AuditLog}

  @reschedule_cutoff_hours 24

  @spec reschedule(map(), map()) :: {:ok, map()} | {:error, term()}
  def reschedule(%{status: :confirmed} = appointment, %{slot: new_slot} = attrs) do
    hours_until = hours_until_appointment(appointment.slot)

    if hours_until < @reschedule_cutoff_hours do
      {:error, :too_late_to_reschedule}
    else
      duration = Map.get(attrs, :duration_minutes, appointment.duration_minutes)

      with :ok <-
             ConflictChecker.check_practitioner(
               appointment.practitioner_id,
               new_slot,
               duration
             ),
           :ok <- ConflictChecker.check_client(appointment.client_id, new_slot, duration) do
        rescheduled =
          appointment
          |> Map.put(:slot, new_slot)
          |> Map.put(:duration_minutes, duration)
          |> Map.put(:rescheduled_at, DateTime.utc_now())

        Notifier.send_reschedule_confirmation(rescheduled)

        AuditLog.write(:appointment_rescheduled, %{
          appointment_id: appointment.id,
          old_slot: appointment.slot,
          new_slot: new_slot
        })

        {:ok, rescheduled}
      end
    end
  end

  def reschedule(%{status: _}, _), do: {:error, :appointment_not_reschedulable}

  @spec mark_completed(map(), map()) :: {:ok, map()}
  def mark_completed(appointment, attrs \\ %{}) do
    updated =
      appointment
      |> Map.put(:status, :completed)
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.put(:completion_notes, Map.get(attrs, :notes))

    AuditLog.write(:appointment_completed, %{appointment_id: appointment.id})

    {:ok, updated}
  end

  @spec mark_no_show(map()) :: {:ok, map()}
  def mark_no_show(appointment) do
    updated = Map.put(appointment, :status, :no_show)
    AuditLog.write(:appointment_no_show, %{appointment_id: appointment.id})
    {:ok, updated}
  end

  defp hours_until_appointment(%{start_time: start_time}) do
    DateTime.diff(start_time, DateTime.utc_now(), :second) / 3600
  end
end
```
