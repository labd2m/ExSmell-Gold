```elixir
defmodule Scheduling.BookingService do
  @moduledoc """
  Handles booking creation, modification, and cancellation for scheduling workflows.
  """

  alias Scheduling.{Appointment, Provider, Availability, BookingRecord, NotificationQueue}
  require Logger

  @cancellation_window_hours 24
  @late_fee 25.00

  def book_appointment(provider_id, patient_id, slot_attrs) do
    with {:ok, provider} <- Provider.fetch(provider_id),
         {:ok, slot} <- Availability.find_slot(provider, slot_attrs),
         :ok <- Availability.reserve(slot),
         {:ok, booking} <- BookingRecord.create(provider, patient_id, slot) do
      NotificationQueue.enqueue_confirmation(booking)
      {:ok, booking}
    end
  end

  def reschedule_appointment(booking_id, new_slot_attrs) do
    with {:ok, booking} <- BookingRecord.fetch(booking_id),
         {:ok, provider} <- Provider.fetch(booking.provider_id),
         {:ok, new_slot} <- Availability.find_slot(provider, new_slot_attrs),
         :ok <- Availability.release(booking.slot),
         :ok <- Availability.reserve(new_slot) do
      BookingRecord.update(booking_id, %{slot: new_slot})
    end
  end

  def cancel_booking(booking_id, reason) do
    with {:ok, booking} <- BookingRecord.fetch(booking_id) do
      late_fee =
        case check_late_cancellation(booking) do
          {:fee, fee} -> fee
          :no_fee -> 0.0
        end

      Logger.info("Cancelling booking #{booking_id}: #{reason}")
      Availability.release(booking.slot)
      BookingRecord.update(booking_id, %{status: :cancelled, reason: reason, late_fee: late_fee})
    end
  end

  def confirm_booking(booking_id) do
    BookingRecord.update(booking_id, %{status: :confirmed, confirmed_at: DateTime.utc_now()})
  end

  def compute_appointment_pricing(appointment_id) do
    appointment = Appointment.get!(appointment_id)

    duration = Appointment.duration_minutes(appointment)
    service_type = Appointment.service_type(appointment)
    hourly_rate = Appointment.provider_rate(appointment)
    insurance = Appointment.insurance_coverage(appointment)
    add_ons = Appointment.add_ons(appointment)
    cancellation_policy = Appointment.cancellation_policy(appointment)

    base_fee = hourly_rate * (duration / 60.0)

    add_on_total =
      Enum.reduce(add_ons, 0.0, fn add_on, acc ->
        acc + add_on.price
      end)

    insurance_discount =
      case insurance do
        %{type: :full_coverage} -> base_fee
        %{type: :partial, pct: pct} -> base_fee * pct / 100.0
        _ -> 0.0
      end

    cancellation_fee =
      if appointment.status == :cancelled do
        hours_before = DateTime.diff(appointment.start_time, DateTime.utc_now(), :hour)

        if hours_before < cancellation_policy.min_hours_before,
          do: cancellation_policy.fee,
          else: 0.0
      else
        0.0
      end

    patient_owes = base_fee - insurance_discount + add_on_total + cancellation_fee

    %{
      appointment_id: appointment.id,
      service_type: service_type,
      duration_minutes: duration,
      hourly_rate: hourly_rate,
      base_fee: Float.round(base_fee, 2),
      insurance_discount: Float.round(insurance_discount, 2),
      add_on_total: Float.round(add_on_total, 2),
      cancellation_fee: cancellation_fee,
      patient_owes: Float.round(patient_owes, 2)
    }
  end

  defp check_late_cancellation(booking) do
    hours_until = DateTime.diff(booking.slot.start_time, DateTime.utc_now(), :hour)

    if hours_until < @cancellation_window_hours do
      {:fee, @late_fee}
    else
      :no_fee
    end
  end
end
```
