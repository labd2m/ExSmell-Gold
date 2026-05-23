```elixir
defmodule Hotel.RoomPricingManager do
  @moduledoc """
  Manages room pricing, amenity entitlements, housekeeping scheduling,
  and seasonal rate adjustment for different room categories
  at the property management system.
  """

  alias Hotel.{Room, Reservation, HousekeepingQueue, RevenueTracker, GuestPortal}

  @peak_season_months [6, 7, 8, 12]
  @shoulder_months [3, 4, 5, 9, 10]

  def create_reservation(guest_id, room_id, check_in, check_out) do
    with {:ok, room}  <- Room.fetch(room_id),
         :ok          <- validate_availability(room, check_in, check_out),
         {:ok, res}   <- build_reservation(guest_id, room, check_in, check_out),
         :ok          <- GuestPortal.send_confirmation(guest_id, res) do
      {:ok, res}
    end
  end

  defp build_reservation(guest_id, room, check_in, check_out) do
    nights      = Date.diff(check_out, check_in)
    base_rate   = get_base_nightly_rate(room.category)
    nightly     = apply_seasonal_multiplier(base_rate, check_in)
    total       = Float.round(nightly * nights, 2)
    amenities   = get_included_amenities(room.category)

    res = %Reservation{
      guest_id:         guest_id,
      room_id:          room.id,
      room_category:    room.category,
      check_in:         check_in,
      check_out:        check_out,
      nights:           nights,
      nightly_rate:     nightly,
      total_amount:     total,
      amenities:        amenities,
      status:           :confirmed,
      booked_at:        DateTime.utc_now()
    }

    Reservation.insert(res)
  end

  defp validate_availability(room, check_in, check_out) do
    if Reservation.available?(room.id, check_in, check_out) do
      :ok
    else
      {:error, :room_not_available}
    end
  end

  def schedule_housekeeping(%Room{} = room) do
    interval_hours = get_housekeeping_interval_hours(room.category)
    HousekeepingQueue.schedule(room.id, interval_hours: interval_hours)
  end

  def get_base_nightly_rate(:standard), do: 89.00
  def get_base_nightly_rate(:deluxe),   do: 149.00
  def get_base_nightly_rate(:suite),    do: 299.00
  def get_base_nightly_rate(_),         do: 69.00

  def get_included_amenities(:standard) do
    [:wifi, :parking, :continental_breakfast]
  end

  def get_included_amenities(:deluxe) do
    [:wifi, :parking, :full_breakfast, :minibar, :room_service]
  end

  def get_included_amenities(:suite) do
    [:wifi, :valet_parking, :full_breakfast, :minibar, :room_service,
     :butler_service, :airport_transfer, :spa_access]
  end

  def get_included_amenities(_) do
    [:wifi]
  end

  def get_housekeeping_interval_hours(:standard), do: 24
  def get_housekeeping_interval_hours(:deluxe),   do: 12
  def get_housekeeping_interval_hours(:suite),    do: 6
  def get_housekeeping_interval_hours(_),         do: 24

  def apply_seasonal_multiplier(rate, %Date{month: month}) when month in @peak_season_months do
    Float.round(rate * 1.35, 2)
  end

  def apply_seasonal_multiplier(rate, %Date{month: month}) when month in @shoulder_months do
    Float.round(rate * 1.15, 2)
  end

  def apply_seasonal_multiplier(rate, _date) do
    rate
  end

  def cancel_reservation(%Reservation{check_in: check_in} = res) do
    days_until = Date.diff(check_in, Date.utc_today())

    penalty = cond do
      days_until >= 7  -> 0.0
      days_until >= 3  -> res.nightly_rate
      true             -> res.total_amount * 0.5
    end

    updated = %{res | status: :cancelled, cancellation_penalty: penalty}
    with {:ok, saved} <- Reservation.update(updated) do
      RevenueTracker.record_cancellation(saved, penalty)
      GuestPortal.send_cancellation_notice(saved.guest_id, saved, penalty)
      {:ok, saved}
    end
  end

  def list_room_categories, do: [:standard, :deluxe, :suite]
end
```
