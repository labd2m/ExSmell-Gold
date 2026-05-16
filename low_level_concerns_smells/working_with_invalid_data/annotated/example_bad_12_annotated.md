# Code Smell: Working with invalid data

- **Smell name:** Working with invalid data
- **Expected smell location:** `book_appointment/2`, where `duration_minutes` is pulled from an external booking params map and forwarded to `CalendarClient.reserve_slot/3` without validation
- **Affected function(s):** `book_appointment/2`, `compute_end_time/2`
- **Short explanation:** `duration_minutes` is obtained from the caller-supplied `booking_params` map without any type or range check. It is passed to `compute_end_time/2`, which calls `DateTime.add/3` using the raw value, and subsequently forwarded to `CalendarClient.reserve_slot/3`. If a string, nil, or negative value is provided, the error will propagate into `DateTime.add/3` or the calendar client internals with no indication that the root cause is an unvalidated duration at the booking boundary.

```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Manages appointment booking for service-based businesses, handling
  availability checks, slot reservation, and confirmation dispatch.
  """

  alias Scheduling.CalendarClient
  alias Scheduling.AvailabilityChecker
  alias Scheduling.ProviderRegistry
  alias Notifications.SmsDispatcher

  @min_notice_hours 1
  @confirmation_template "appointment_confirmed_v2"
  @supported_service_types [:consultation, :follow_up, :procedure, :assessment]

  def book_appointment(booking_params, requester_id) do
    service_type = Map.fetch!(booking_params, :service_type)
    provider_id = Map.fetch!(booking_params, :provider_id)
    requested_start = Map.fetch!(booking_params, :start_time)

    with {:ok, service_type} <- validate_service_type(service_type),
         {:ok, provider} <- ProviderRegistry.fetch(provider_id),
         :ok <- assert_sufficient_notice(requested_start),
         {:ok, slot} <- build_slot(booking_params, requested_start),
         :ok <- AvailabilityChecker.assert_available(provider, slot),
         {:ok, booking_ref} <- CalendarClient.reserve_slot(provider, slot, requester_id),
         :ok <- SmsDispatcher.send_template(provider.contact_phone, @confirmation_template, slot) do
      {:ok,
       %{
         booking_ref: booking_ref,
         provider_id: provider_id,
         start_time: slot.start_time,
         end_time: slot.end_time,
         service_type: service_type
       }}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `duration_minutes` is read from
  # the external `booking_params` map with no validation of type or value.
  # It is passed directly to `compute_end_time/2`, which calls
  # `DateTime.add(start_time, duration_minutes * 60, :second)`.
  # If the caller provides a binary like "30", a float, nil, or a negative
  # number, the error will surface inside `DateTime.add/3` or inside
  # `CalendarClient.reserve_slot/3`, with no message linking the fault
  # back to the unvalidated `duration_minutes` at the booking entry point.
  defp build_slot(booking_params, start_time) do
    duration_minutes = Map.get(booking_params, :duration_minutes, 30)
    location = Map.get(booking_params, :location, :remote)
    notes = Map.get(booking_params, :notes, "")

    end_time = compute_end_time(start_time, duration_minutes)

    slot = %{
      start_time: start_time,
      end_time: end_time,
      duration_minutes: duration_minutes,
      location: location,
      notes: notes,
      created_at: DateTime.utc_now()
    }

    {:ok, slot}
  end
  # VALIDATION: SMELL END

  defp compute_end_time(start_time, duration_minutes) do
    DateTime.add(start_time, duration_minutes * 60, :second)
  end

  defp validate_service_type(type) when type in @supported_service_types, do: {:ok, type}
  defp validate_service_type(type), do: {:error, {:unsupported_service_type, type}}

  defp assert_sufficient_notice(start_time) do
    min_allowed = DateTime.add(DateTime.utc_now(), @min_notice_hours * 3600, :second)

    if DateTime.compare(start_time, min_allowed) == :gt do
      :ok
    else
      {:error, :insufficient_notice}
    end
  end
end
```
