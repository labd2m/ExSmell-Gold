```elixir
defmodule Scheduling.SlotConfirmer do
  @moduledoc """
  Confirms appointment slot bookings by persisting the reservation,
  sending calendar invites, and issuing reminder schedules.
  """

  alias Scheduling.{Appointment, ReminderScheduler, CalendarInvite, AvailabilityLedger}

  require Logger

  @confirmation_lead_time_seconds 300

  @spec confirm_slot(String.t(), String.t()) ::
          {:ok, Appointment.t()} | {:error, atom()}
  def confirm_slot(slot_id, customer_id, timezone \\ "UTC") do
    with {:ok, slot} <- fetch_slot(slot_id),
         :ok <- validate_slot_available(slot),
         {:ok, local_start} <- to_local_time(slot.starts_at, timezone),
         {:ok, local_end} <- to_local_time(slot.ends_at, timezone),
         {:ok, appt} <-
           Appointment.create(%{
             slot_id: slot_id,
             customer_id: customer_id,
             provider_id: slot.provider_id,
             starts_at: slot.starts_at,
             ends_at: slot.ends_at,
             local_starts_at: local_start,
             local_ends_at: local_end,
             timezone: timezone
           }),
         :ok <- AvailabilityLedger.mark_taken(slot_id, appt.id),
         :ok <- CalendarInvite.send(appt, customer_id),
         :ok <- ReminderScheduler.schedule(appt, customer_id) do
      Logger.info(
        "Slot confirmed slot=#{slot_id} appt=#{appt.id} customer=#{customer_id} tz=#{timezone}"
      )

      {:ok, appt}
    else
      {:error, :slot_taken} ->
        Logger.warning("Slot conflict slot=#{slot_id} customer=#{customer_id}")
        {:error, :slot_taken}

      {:error, reason} ->
        Logger.error("Slot confirm failed slot=#{slot_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_slot(slot_id) do
    case :ets.lookup(:slots, slot_id) do
      [{^slot_id, slot}] -> {:ok, slot}
      [] -> {:error, :slot_not_found}
    end
  end

  defp validate_slot_available(%{status: :available}), do: :ok
  defp validate_slot_available(_slot), do: {:error, :slot_taken}

  defp to_local_time(%DateTime{} = utc_dt, timezone) do
    case DateTime.shift_zone(utc_dt, timezone) do
      {:ok, local_dt} -> {:ok, local_dt}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end
end

defmodule Scheduling.BookingController do
  alias Scheduling.SlotConfirmer

  def book(conn) do
    %{slot_id: slot_id, customer_id: customer_id} = conn.body_params

    case SlotConfirmer.confirm_slot(slot_id, customer_id) do
      {:ok, appt} ->
        send_resp(conn, 201, Jason.encode!(%{appointment_id: appt.id}))

      {:error, :slot_taken} ->
        send_resp(conn, 409, Jason.encode!(%{error: "slot_unavailable"}))

      {:error, reason} ->
        send_resp(conn, 422, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp send_resp(conn, status, body) do
    %{conn | status: status, resp_body: body}
  end
end
```
