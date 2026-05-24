# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `AppointmentBooker.book/3` function
- **Affected function(s):** `AppointmentBooker.book/3`
- **Short explanation:** `AppointmentBooker.book/3` fetches a `Provider` struct and a `ServiceType` struct, then directly reads internal fields (`.working_hours`, `.buffer_minutes`, `.blocked_dates`, `.duration_minutes`, `.requires_intake_form`) to perform availability and eligibility checks. This logic should live inside `Provider` and `ServiceType` as dedicated query functions rather than being scattered into the booking module.

---

```elixir
defmodule MyApp.Scheduling.AppointmentBooker do
  @moduledoc """
  Books appointments for clients with service providers.
  Validates slot availability and enforces service-specific booking rules.
  """

  alias MyApp.Scheduling.{Provider, ServiceType, Appointment, SlotCalculator}
  alias MyApp.Clients.Client
  alias MyApp.Notifications.AppointmentMailer

  def book(provider_id, service_type_id, requested_at) do
    with {:ok, provider}     <- Provider.fetch(provider_id),
         {:ok, service_type} <- ServiceType.fetch(service_type_id),
         {:ok, client}       <- Client.current() do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because book/3 directly reads .working_hours,
      # .buffer_minutes, and .blocked_dates from the Provider struct, and
      # .duration_minutes and .requires_intake_form from the ServiceType struct.
      # These are internal scheduling constraints that belong to their respective
      # modules and should be queried via encapsulated functions, not accessed raw.
      working_hours   = provider.working_hours
      buffer_minutes  = provider.buffer_minutes
      blocked_dates   = provider.blocked_dates

      duration         = service_type.duration_minutes
      needs_intake     = service_type.requires_intake_form

      requested_day = DateTime.to_date(requested_at)

      cond do
        requested_day in blocked_dates ->
          {:error, :provider_unavailable}

        not SlotCalculator.within_hours?(requested_at, working_hours) ->
          {:error, :outside_working_hours}

        needs_intake and not Client.has_intake_form?(client.id, service_type_id) ->
          {:error, :intake_form_required}

        not slot_free?(provider_id, requested_at, duration, buffer_minutes) ->
          {:error, :slot_not_available}

        true ->
          create_appointment(provider, service_type, client, requested_at, duration)
      end
      # VALIDATION: SMELL END
    end
  end

  def cancel(appointment_id, reason \\ nil) do
    case Appointment.fetch(appointment_id) do
      nil ->
        {:error, :not_found}

      %{status: :completed} ->
        {:error, :cannot_cancel_completed}

      appointment ->
        updated = %{appointment |
          status:       :cancelled,
          cancelled_at: DateTime.utc_now(),
          cancel_reason: reason
        }
        Appointment.save(updated)
        AppointmentMailer.deliver_cancellation(updated)
        {:ok, updated}
    end
  end

  def reschedule(appointment_id, new_time) do
    case Appointment.fetch(appointment_id) do
      nil -> {:error, :not_found}
      appt ->
        cancel(appointment_id, :rescheduled)
        book(appt.provider_id, appt.service_type_id, new_time)
    end
  end

  def list_upcoming(provider_id) do
    now = DateTime.utc_now()
    :ets.tab2list(:appointments)
    |> Enum.map(fn {_, a} -> a end)
    |> Enum.filter(fn a ->
      a.provider_id == provider_id and
        a.status == :confirmed and
        DateTime.compare(a.starts_at, now) == :gt
    end)
    |> Enum.sort_by(& &1.starts_at)
  end

  # --- Private helpers ---

  defp slot_free?(provider_id, starts_at, duration, buffer) do
    ends_at = DateTime.add(starts_at, (duration + buffer) * 60, :second)
    existing = list_upcoming(provider_id)
    Enum.all?(existing, fn appt ->
      DateTime.compare(appt.ends_at, starts_at) != :gt or
        DateTime.compare(ends_at, appt.starts_at) != :gt
    end)
  end

  defp create_appointment(provider, service_type, client, starts_at, duration) do
    appt = %{
      id:              generate_id(),
      provider_id:     provider.id,
      service_type_id: service_type.id,
      client_id:       client.id,
      starts_at:       starts_at,
      ends_at:         DateTime.add(starts_at, duration * 60, :second),
      duration:        duration,
      status:          :confirmed,
      created_at:      DateTime.utc_now()
    }
    Appointment.save(appt)
    AppointmentMailer.deliver_confirmation(appt)
    {:ok, appt}
  end

  defp generate_id do
    "APT-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
