```elixir
defmodule Scheduling.AppointmentBook do
  @moduledoc """
  Manages appointment booking, rescheduling, and cancellation
  for service providers with configurable availability windows.
  """

  require Logger

  alias Scheduling.{Appointment, TimeSlot, WaitlistEntry}
  alias Providers.{Provider, Calendar, Availability, ServiceType}
  alias Accounts.BookingPreference

  @booking_advance_days 60

  def list_available_slots(provider_id, date) do
    TimeSlot.list(provider_id: provider_id, date: date, status: :available)
  end

  def cancel_appointment(%Appointment{status: :confirmed} = appt, reason) do
    with {:ok, updated} <- Appointment.persist(%{appt |
           status:       :cancelled,
           cancel_reason: reason,
           cancelled_at:  DateTime.utc_now()
         }) do
      TimeSlot.release(appt.slot_id)
      Logger.info("Appointment #{appt.id} cancelled")
      {:ok, updated}
    end
  end

  def cancel_appointment(%Appointment{status: status}, _reason),
    do: {:error, "Cannot cancel appointment with status: #{status}"}

  def reschedule(%Appointment{status: :confirmed} = appt, new_slot_id) do
    with {:ok, slot} <- TimeSlot.fetch(new_slot_id),
         true        <- slot.provider_id == appt.provider_id,
         :ok         <- TimeSlot.reserve(new_slot_id) do
      TimeSlot.release(appt.slot_id)
      Appointment.persist(%{appt | slot_id: new_slot_id, rescheduled_at: DateTime.utc_now()})
    else
      false       -> {:error, :provider_mismatch}
      {:error, e} -> {:error, e}
    end
  end

  def reschedule(%Appointment{status: status}, _slot_id),
    do: {:error, "Cannot reschedule appointment in #{status} state"}

  def book(customer_id, provider_id, slot_id, service_type_code) do
    provider     = Provider.find(provider_id)
    service_type = ServiceType.find(service_type_code)
    pref         = BookingPreference.for_customer(customer_id)

    if provider.accepting_new_clients != true do
      {:error, :provider_not_accepting_clients}
    else
      availability = Availability.for_provider(provider_id)

      if service_type.duration_minutes > availability.slot_duration_minutes do
        {:error, :slot_too_short_for_service}
      else
        calendar = Calendar.for_provider(provider.calendar_id)

        with {:ok, _slot} <- TimeSlot.fetch(slot_id),
             :ok          <- TimeSlot.reserve(slot_id) do
          appointment = %Appointment{
            customer_id:          customer_id,
            provider_id:          provider_id,
            slot_id:              slot_id,
            service_type:         service_type_code,
            status:               :confirmed,
            timezone:             provider.timezone,
            reminder_minutes:     pref.preferred_reminder_minutes,
            requires_intake:      service_type.requires_intake_form,
            sync_calendar:        calendar.sync_enabled,
            external_calendar_id: calendar.external_id,
            booked_at:            DateTime.utc_now()
          }

          with {:ok, saved} <- Appointment.persist(appointment) do
            Logger.info("Appointment #{saved.id} booked for customer #{customer_id}")
            {:ok, saved}
          end
        end
      end
    end
  end

  def join_waitlist(customer_id, provider_id, preferred_dates) do
    entry = %WaitlistEntry{
      customer_id:     customer_id,
      provider_id:     provider_id,
      preferred_dates: preferred_dates,
      joined_at:       DateTime.utc_now()
    }

    WaitlistEntry.persist(entry)
  end

  def confirm_from_waitlist(slot_id) do
    with {:ok, slot}  <- TimeSlot.fetch(slot_id),
         {:ok, entry} <- WaitlistEntry.next_for_provider(slot.provider_id) do
      book(entry.customer_id, slot.provider_id, slot_id, entry.service_type_code)
    end
  end

  def upcoming_for_customer(customer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    Appointment.list(customer_id: customer_id, status: :confirmed, limit: limit)
  end
end
```
