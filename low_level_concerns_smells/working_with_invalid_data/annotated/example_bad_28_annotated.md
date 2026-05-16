# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `AppointmentScheduler.book/4`, where `duration_minutes` is passed to `DateTime.add/3`
- **Affected function(s):** `book/4`
- **Short explanation:** The `duration_minutes` field taken from `slot.duration_minutes` is passed directly to `DateTime.add/3` without any check that it is an integer. If the slot record was built from a JSON API response and deserialization returned a float or a string, `DateTime.add/3` raises a `FunctionClauseError` deep in the DateTime module with no reference to the `book/4` boundary where the invalid value was first used.

```elixir
defmodule MyApp.Scheduling.AppointmentScheduler do
  @moduledoc """
  Manages booking, rescheduling, and cancellation of provider appointments.
  Supports multi-resource scheduling, buffer times, and conflict detection.
  """

  require Logger

  alias MyApp.Scheduling.{
    SlotRegistry,
    AppointmentRecord,
    ConflictDetector,
    ReminderQueue,
    ProviderCalendar
  }

  alias MyApp.Accounts.{Customer, Provider}

  @booking_window_days 90
  @min_advance_booking_minutes 30
  @cancellation_window_hours 24
  @reminder_intervals_minutes [1440, 60]

  @type booking_opts :: [
          notes: String.t(),
          send_reminders: boolean(),
          buffer_after_minutes: non_neg_integer()
        ]

  @spec book(Customer.t(), String.t(), String.t(), booking_opts()) ::
          {:ok, AppointmentRecord.t()} | {:error, atom()}
  def book(customer, provider_id, slot_id, opts \\ []) do
    notes = Keyword.get(opts, :notes, "")
    send_reminders = Keyword.get(opts, :send_reminders, true)
    buffer_after = Keyword.get(opts, :buffer_after_minutes, 0)

    with {:ok, provider} <- Provider.fetch(provider_id),
         {:ok, slot} <- SlotRegistry.fetch(slot_id),
         :ok <- check_slot_available(slot),
         :ok <- check_booking_window(slot.starts_at),
         :ok <- check_advance_booking(slot.starts_at) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `slot.duration_minutes` is passed directly
      # VALIDATION: to `DateTime.add/3` without checking that it is an integer.
      # VALIDATION: Slot records deserialized from external calendar APIs may have
      # VALIDATION: duration as a float or string. `DateTime.add/3` requires an integer
      # VALIDATION: and will raise a FunctionClauseError inside the DateTime module,
      # VALIDATION: with no trace back to the `book/4` entry point.
      ends_at = DateTime.add(slot.starts_at, slot.duration_minutes * 60, :second)
      # VALIDATION: SMELL END

      blocked_until =
        if buffer_after > 0 do
          DateTime.add(ends_at, buffer_after * 60, :second)
        else
          ends_at
        end

      with :ok <- ConflictDetector.check(provider_id, slot.starts_at, blocked_until),
           {:ok, appointment} <-
             AppointmentRecord.create(%{
               id: Ecto.UUID.generate(),
               customer_id: customer.id,
               provider_id: provider_id,
               slot_id: slot_id,
               starts_at: slot.starts_at,
               ends_at: ends_at,
               duration_minutes: slot.duration_minutes,
               notes: notes,
               status: :confirmed,
               booked_at: DateTime.utc_now()
             }),
           :ok <- SlotRegistry.mark_booked(slot_id, appointment.id),
           :ok <- ProviderCalendar.block(provider_id, slot.starts_at, blocked_until) do
        if send_reminders do
          Enum.each(@reminder_intervals_minutes, fn offset ->
            remind_at = DateTime.add(slot.starts_at, -offset * 60, :second)
            ReminderQueue.schedule(appointment.id, remind_at)
          end)
        end

        Logger.info(
          "Appointment booked: #{appointment.id} customer=#{customer.id} " <>
            "provider=#{provider_id} starts_at=#{slot.starts_at}"
        )

        {:ok, appointment}
      end
    end
  end

  @spec cancel(String.t(), String.t(), String.t()) ::
          {:ok, AppointmentRecord.t()} | {:error, atom()}
  def cancel(appointment_id, cancelled_by_id, reason \\ "customer_request") do
    with {:ok, appt} <- AppointmentRecord.fetch(appointment_id),
         :ok <- check_cancellation_window(appt.starts_at),
         :ok <- authorize_cancellation(appt, cancelled_by_id) do
      AppointmentRecord.update(appointment_id, %{
        status: :cancelled,
        cancellation_reason: reason,
        cancelled_at: DateTime.utc_now(),
        cancelled_by_id: cancelled_by_id
      })

      SlotRegistry.mark_available(appt.slot_id)
      ProviderCalendar.unblock(appt.provider_id, appt.starts_at, appt.ends_at)
      ReminderQueue.cancel_all(appointment_id)
    end
  end

  @spec upcoming(String.t(), pos_integer()) ::
          {:ok, [AppointmentRecord.t()]} | {:error, atom()}
  def upcoming(customer_id, limit \\ 10) do
    AppointmentRecord.list_upcoming(customer_id, DateTime.utc_now(), limit)
  end

  # Private helpers

  defp check_slot_available(%{status: :available}), do: :ok
  defp check_slot_available(_), do: {:error, :slot_unavailable}

  defp check_booking_window(starts_at) do
    cutoff = DateTime.add(DateTime.utc_now(), @booking_window_days * 86_400, :second)
    if DateTime.compare(starts_at, cutoff) == :lt, do: :ok, else: {:error, :outside_booking_window}
  end

  defp check_advance_booking(starts_at) do
    min_start = DateTime.add(DateTime.utc_now(), @min_advance_booking_minutes * 60, :second)
    if DateTime.compare(starts_at, min_start) == :gt, do: :ok, else: {:error, :insufficient_advance_notice}
  end

  defp check_cancellation_window(starts_at) do
    cutoff = DateTime.add(DateTime.utc_now(), @cancellation_window_hours * 3600, :second)
    if DateTime.compare(starts_at, cutoff) == :gt, do: :ok, else: {:error, :outside_cancellation_window}
  end

  defp authorize_cancellation(%{customer_id: cid}, cid), do: :ok
  defp authorize_cancellation(%{provider_id: pid}, pid), do: :ok
  defp authorize_cancellation(_, _), do: {:error, :unauthorized}
end
```
