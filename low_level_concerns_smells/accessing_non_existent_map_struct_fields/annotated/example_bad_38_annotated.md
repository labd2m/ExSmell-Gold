# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Scheduling.AppointmentBook.book/2`, where optional booking constraints are accessed dynamically
- **Affected function(s):** `book/2`
- **Short explanation:** The function reads `:buffer_minutes`, `:allow_overlap`, and `:confirmation_required` from the slot map using bracket access. Absent keys return `nil`, causing the buffer window calculation to operate on `nil + integer` (runtime crash) and overlap/confirmation logic to silently use incorrect defaults.

```elixir
defmodule Scheduling.AppointmentBook do
  @moduledoc """
  Manages appointment booking for multi-provider scheduling.
  Enforces availability windows, buffer times between appointments,
  and optional confirmation workflows.
  """

  require Logger

  @min_duration_minutes 15
  @max_duration_minutes 480

  @type provider :: %{
          id: String.t(),
          name: String.t(),
          timezone: String.t()
        }

  @type slot :: %{
          provider_id: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          optional(:buffer_minutes) => non_neg_integer(),
          optional(:allow_overlap) => boolean(),
          optional(:confirmation_required) => boolean(),
          optional(:max_attendees) => pos_integer()
        }

  @type booking_request :: %{
          patient_id: String.t(),
          provider_id: String.t(),
          requested_start: DateTime.t(),
          duration_minutes: pos_integer(),
          notes: String.t()
        }

  @spec book(slot(), booking_request()) ::
          {:ok, map()} | {:error, String.t()}
  def book(slot, request) do
    with :ok <- validate_duration(request.duration_minutes),
         :ok <- validate_provider_match(slot, request),
         :ok <- validate_window(slot, request) do
      finalise_booking(slot, request)
    end
  end

  defp validate_duration(minutes) when minutes < @min_duration_minutes,
    do: {:error, "appointment duration below minimum of #{@min_duration_minutes} minutes"}
  defp validate_duration(minutes) when minutes > @max_duration_minutes,
    do: {:error, "appointment duration above maximum of #{@max_duration_minutes} minutes"}
  defp validate_duration(_), do: :ok

  defp validate_provider_match(slot, request) do
    if slot.provider_id == request.provider_id do
      :ok
    else
      {:error, "slot provider #{slot.provider_id} does not match request provider #{request.provider_id}"}
    end
  end

  defp validate_window(slot, request) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `slot[:buffer_minutes]` and `slot[:allow_overlap]`
    # use dynamic bracket access on a plain map. When `:buffer_minutes` is absent, `nil`
    # is returned, and the arithmetic `DateTime.add(slot.end_time, nil, :minute)` will
    # crash at runtime. When `:allow_overlap` is absent, `nil` is treated as falsy,
    # silently disabling overlap permission even if it was intended to be allowed.
    buffer_minutes = slot[:buffer_minutes]
    allow_overlap  = slot[:allow_overlap]
    # VALIDATION: SMELL END

    appointment_end = DateTime.add(request.requested_start, request.duration_minutes, :minute)
    buffered_end    = DateTime.add(slot.end_time, buffer_minutes, :minute)

    cond do
      DateTime.compare(request.requested_start, slot.start_time) == :lt ->
        {:error, "appointment starts before slot opens"}

      DateTime.compare(appointment_end, buffered_end) == :gt ->
        {:error, "appointment (with buffer) extends beyond slot end"}

      not allow_overlap and overlaps_existing?(slot.provider_id, request.requested_start, appointment_end) ->
        {:error, "time conflicts with an existing appointment"}

      true ->
        :ok
    end
  end

  defp overlaps_existing?(_provider_id, _start, _end_time) do
    false
  end

  defp finalise_booking(slot, request) do
    confirmation_required = slot[:confirmation_required]

    status = if confirmation_required, do: :pending_confirmation, else: :confirmed

    booking = %{
      id:              generate_booking_id(),
      patient_id:      request.patient_id,
      provider_id:     request.provider_id,
      start_time:      request.requested_start,
      end_time:        DateTime.add(request.requested_start, request.duration_minutes, :minute),
      duration_minutes: request.duration_minutes,
      status:          status,
      notes:           request.notes,
      booked_at:       DateTime.utc_now()
    }

    Logger.info("Booking #{booking.id} created with status=#{status} for patient=#{request.patient_id}")
    {:ok, booking}
  end

  @spec cancel(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def cancel(%{status: :confirmed} = booking, reason) do
    updated = %{booking | status: :cancelled, cancellation_reason: reason,
                           cancelled_at: DateTime.utc_now()}
    Logger.info("Booking #{booking.id} cancelled: #{reason}")
    {:ok, updated}
  end

  def cancel(%{status: status}, _), do: {:error, "cannot cancel a booking with status #{status}"}

  defp generate_booking_id do
    "BK-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
