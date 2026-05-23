```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Handles appointment creation, availability checking, and slot listing
  for a healthcare scheduling platform.
  """

  require Logger
  alias Scheduling.{CalendarStore, NotificationService, Provider}

  @business_hours_start 8
  @business_hours_end 20
  @valid_durations_minutes [15, 30, 45, 60, 90, 120]
  @valid_days ["monday", "tuesday", "wednesday", "thursday", "friday"]

  @spec book_appointment(String.t(), String.t(), String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def book_appointment(patient_id, provider_id, day_of_week, start_hour, duration_minutes)
      when is_binary(patient_id) and is_binary(provider_id) and
             is_binary(day_of_week) and is_integer(start_hour) and
             is_integer(duration_minutes) do
    with :ok <- validate_slot(day_of_week, start_hour, duration_minutes),
         {:ok, provider} <- Provider.fetch(provider_id),
         true <- is_slot_available?(provider, day_of_week, start_hour, duration_minutes),
         appointment_id = generate_appointment_id() do
      end_hour = start_hour + div(duration_minutes, 60)
      end_minute = rem(duration_minutes, 60)

      appointment = %{
        id: appointment_id,
        patient_id: patient_id,
        provider_id: provider_id,
        day_of_week: day_of_week,
        start_hour: start_hour,
        duration_minutes: duration_minutes,
        end_hour: end_hour,
        end_minute: end_minute,
        status: "confirmed",
        created_at: DateTime.utc_now()
      }

      case CalendarStore.insert(appointment) do
        :ok ->
          NotificationService.send_confirmation(patient_id, appointment)
          Logger.info("Booked #{appointment_id}: #{day_of_week} #{start_hour}:00 x #{duration_minutes}min")
          {:ok, appointment}

        {:error, reason} ->
          {:error, "booking_failed: #{reason}"}
      end
    else
      false -> {:error, "slot_not_available"}
      error -> error
    end
  end

  def book_appointment(_, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec is_slot_available?(map(), String.t(), integer(), integer()) :: boolean()
  def is_slot_available?(provider, day_of_week, start_hour, duration_minutes) do
    end_minutes_total = start_hour * 60 + duration_minutes
    end_hour = div(end_minutes_total, 60)

    existing = CalendarStore.fetch_for_provider(provider.id, day_of_week)

    no_overlap =
      Enum.all?(existing, fn appt ->
        appt_end = appt.start_hour * 60 + appt.duration_minutes
        appt.start_hour * 60 >= end_minutes_total or
          start_hour * 60 >= appt_end
      end)

    end_hour <= @business_hours_end and no_overlap
  end

  @spec list_available_slots(String.t(), String.t(), integer()) :: list(map())
  def list_available_slots(provider_id, day_of_week, duration_minutes)
      when is_binary(provider_id) and is_binary(day_of_week) and is_integer(duration_minutes) do
    case Provider.fetch(provider_id) do
      {:ok, provider} ->
        @business_hours_start..(@business_hours_end - 1)
        |> Enum.filter(fn hour ->
          is_slot_available?(provider, day_of_week, hour, duration_minutes)
        end)
        |> Enum.map(fn hour ->
          %{day: day_of_week, start_hour: hour, duration_minutes: duration_minutes}
        end)

      {:error, _} ->
        []
    end
  end

  @spec validate_slot(String.t(), integer(), integer()) :: :ok | {:error, String.t()}
  defp validate_slot(day_of_week, start_hour, duration_minutes) do
    cond do
      day_of_week not in @valid_days ->
        {:error, "invalid_day_of_week"}

      start_hour < @business_hours_start or start_hour >= @business_hours_end ->
        {:error, "start_hour_outside_business_hours"}

      duration_minutes not in @valid_durations_minutes ->
        {:error, "invalid_duration"}

      start_hour * 60 + duration_minutes > @business_hours_end * 60 ->
        {:error, "appointment_would_exceed_business_hours"}

      true ->
        :ok
    end
  end

  defp generate_appointment_id do
    "APT-" <> Base.encode16(:crypto.strong_rand_bytes(5))
  end
end
```
