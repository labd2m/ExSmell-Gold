```elixir
defmodule Scheduling.CalendarEntry do
  @moduledoc "Represents a bookable calendar slot for a provider."

  defstruct [
    :id,
    :provider_id,
    :service_type,
    :starts_at,
    :ends_at,
    :capacity,
    :bookings_count,
    :status,
    :booking_open_at,
    :booking_close_at,
    :location
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      provider_id: "PROV-012",
      service_type: :consultation,
      starts_at: ~U[2024-04-01 10:00:00Z],
      ends_at: ~U[2024-04-01 11:00:00Z],
      capacity: 3,
      bookings_count: 1,
      status: :open,
      booking_open_at: ~U[2024-03-15 00:00:00Z],
      booking_close_at: ~U[2024-03-31 23:59:59Z],
      location: "Room 4B"
    }
  end

  def is_open?(%__MODULE__{status: :open}), do: true
  def is_open?(_), do: false

  def remaining_capacity(%__MODULE__{capacity: cap, bookings_count: booked}) do
    cap - booked
  end

  def within_booking_window?(%__MODULE__{booking_open_at: opens, booking_close_at: closes}) do
    now = DateTime.utc_now()
    DateTime.compare(now, opens) in [:gt, :eq] and DateTime.compare(now, closes) in [:lt, :eq]
  end

  def duration_minutes(%__MODULE__{starts_at: s, ends_at: e}) do
    DateTime.diff(e, s, :second) |> div(60)
  end

  def provider_label(%__MODULE__{provider_id: pid, service_type: st}) do
    "#{pid}/#{st}"
  end
end

defmodule Scheduling.Booking do
  @moduledoc "A confirmed booking for a calendar slot."

  defstruct [:id, :slot_id, :user_id, :confirmed_at, :notes]

  def create(slot_id, user_id, notes) do
    %__MODULE__{
      id: "BK-#{:rand.uniform(99_999)}",
      slot_id: slot_id,
      user_id: user_id,
      confirmed_at: DateTime.utc_now(),
      notes: notes
    }
  end
end

defmodule Scheduling.BookingService do
  @moduledoc """
  Manages the full lifecycle of slot bookings, from availability checks
  through confirmation and cancellation.
  """

  alias Scheduling.{CalendarEntry, Booking}
  require Logger

  @doc """
  Books a slot for `user_id`, verifying availability and booking window.
  Returns `{:ok, Booking.t()}` or `{:error, reason}`.
  """
  def book(slot_id, user_id, notes \\ nil) do
    case check_slot_availability(slot_id, user_id) do
      :ok ->
        booking = Booking.create(slot_id, user_id, notes)
        Logger.info("Booking confirmed: #{booking.id} for user #{user_id} on slot #{slot_id}")
        {:ok, booking}

      {:error, reason} ->
        Logger.warning("Booking failed for slot #{slot_id}: #{reason}")
        {:error, reason}
    end
  end

  @doc "Cancels an existing booking by ID."
  def cancel(booking_id) do
    Logger.info("Cancelling booking #{booking_id}")
    {:ok, :cancelled}
  end

  defp check_slot_availability(slot_id, user_id) do
    slot = CalendarEntry.get!(slot_id)

    cond do
      not CalendarEntry.is_open?(slot) ->
        {:error, :slot_closed}

      not CalendarEntry.within_booking_window?(slot) ->
        {:error, :outside_booking_window}

      CalendarEntry.remaining_capacity(slot) <= 0 ->
        {:error, :slot_full}

      CalendarEntry.duration_minutes(slot) < 15 ->
        {:error, :slot_too_short}

      true ->
        Logger.debug("Slot #{slot_id} available for user #{user_id}")
        :ok
    end
  end
end
```
