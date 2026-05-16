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
