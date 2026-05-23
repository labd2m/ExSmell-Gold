```elixir
defmodule Scheduling.BookingManager do
  @moduledoc """
  Manages resource bookings (meeting rooms, equipment, personnel slots) and
  prevents double-booking through overlap detection.
  """

  alias Scheduling.{Booking, Resource, Repo, EventLog}

  @buffer_minutes 0


  @doc """
  Creates a new booking for `resource_id` over the given time window.
  Returns `{:ok, booking}` or `{:error, reason}`.
  """
  def book_resource(resource_id, %DateTime{} = starts_at, %DateTime{} = ends_at) do
    with {:ok, resource} <- Resource.fetch(resource_id),
         :ok             <- validate_time_window(starts_at, ends_at),
         :ok             <- check_resource_active(resource) do

      existing_bookings = Repo.list_active_bookings(resource_id)

      overlap =
        Enum.any?(existing_bookings, fn b ->
          DateTime.compare(starts_at, b.ends_at)   == :lt and
          DateTime.compare(ends_at,   b.starts_at) == :gt
        end)

      if overlap do
        {:error, :time_slot_unavailable}
      else
        booking = %Booking{
          resource_id: resource_id,
          booker_id:   resource.default_booker_id,
          starts_at:   starts_at,
          ends_at:     ends_at,
          status:      :confirmed,
          created_at:  DateTime.utc_now()
        }

        case Repo.insert(booking) do
          {:ok, saved} ->
            EventLog.append(:booking_created, %{booking_id: saved.id})
            {:ok, saved}

          {:error, reason} ->
            {:error, {:db_error, reason}}
        end
      end
    end
  end


  @doc """
  Extends an existing booking's end time. Checks that the extended window
  does not overlap with any other booking for the same resource.
  """
  def extend_booking(booking_id, new_ends_at, extended_by_user_id) do
    with {:ok, booking}  <- Repo.fetch_booking(booking_id),
         :ok             <- check_booking_owned(booking, extended_by_user_id),
         :ok             <- validate_extension(booking, new_ends_at) do

      existing_bookings = Repo.list_active_bookings(booking.resource_id)

      other_bookings = Enum.reject(existing_bookings, &(&1.id == booking.id))

      overlap =
        Enum.any?(other_bookings, fn b ->
          DateTime.compare(booking.starts_at, b.ends_at)   == :lt and
          DateTime.compare(new_ends_at,       b.starts_at) == :gt
        end)

      if overlap do
        {:error, :time_slot_unavailable}
      else
        case Repo.update_booking(booking, %{ends_at: new_ends_at}) do
          {:ok, updated} ->
            EventLog.append(:booking_extended, %{
              booking_id:  updated.id,
              new_ends_at: new_ends_at
            })
            {:ok, updated}

          {:error, reason} ->
            {:error, {:db_error, reason}}
        end
      end
    end
  end


  defp validate_time_window(starts_at, ends_at) do
    if DateTime.compare(ends_at, starts_at) == :gt, do: :ok, else: {:error, :invalid_window}
  end

  defp validate_extension(%Booking{ends_at: current_end}, new_ends_at) do
    if DateTime.compare(new_ends_at, current_end) == :gt, do: :ok, else: {:error, :not_an_extension}
  end

  defp check_resource_active(%Resource{active: true}), do: :ok
  defp check_resource_active(_), do: {:error, :resource_inactive}

  defp check_booking_owned(%Booking{booker_id: uid}, uid), do: :ok
  defp check_booking_owned(_, _), do: {:error, :not_owner}
end
```
