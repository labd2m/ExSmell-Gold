```elixir
defmodule MyApp.Scheduling.AppointmentScheduler do
  @moduledoc """
  Handles creation and management of appointments, including recurring
  series, rescheduling, and conflict detection.
  """

  require Logger

  alias MyApp.Scheduling.{Appointment, AppointmentRepo, ConflictChecker, ReminderDispatcher}
  alias MyApp.Accounts.User

  @valid_recurrences [:none, :daily, :weekly, :biweekly, :monthly, :yearly]
  @max_duration_minutes 480
  @advance_booking_days 90

  @doc """
  Books a new appointment for a user, checking for conflicts and scheduling reminders.
  """
  @spec book(User.t(), map()) :: {:ok, Appointment.t()} | {:error, term()}
  def book(%User{id: user_id} = user, params) do
    Logger.info("Booking appointment", user_id: user_id)

    with {:ok, start_dt} <- parse_datetime(params["start_at"]),
         {:ok, end_dt} <- parse_datetime(params["end_at"]),
         :ok <- validate_duration(start_dt, end_dt),
         :ok <- validate_advance_booking(start_dt),
         {:ok, recurrence} <- decode_recurrence(params["recurrence"]),
         :ok <- ConflictChecker.check(user_id, start_dt, end_dt),
         {:ok, appointment} <- create_appointment(user, params, start_dt, end_dt, recurrence) do
      ReminderDispatcher.schedule(appointment)
      Logger.info("Appointment booked", appointment_id: appointment.id)
      {:ok, appointment}
    else
      {:error, reason} = err ->
        Logger.warning("Appointment booking failed", user_id: user_id, reason: inspect(reason))
        err
    end
  end

  @doc """
  Reschedules an existing appointment to a new time slot.
  """
  @spec reschedule(String.t(), map()) :: {:ok, Appointment.t()} | {:error, term()}
  def reschedule(appointment_id, params) do
    with {:ok, appointment} <- AppointmentRepo.get(appointment_id),
         {:ok, start_dt} <- parse_datetime(params["start_at"]),
         {:ok, end_dt} <- parse_datetime(params["end_at"]),
         :ok <- validate_duration(start_dt, end_dt),
         :ok <- ConflictChecker.check(appointment.user_id, start_dt, end_dt, exclude: appointment_id) do
      AppointmentRepo.update(appointment, %{start_at: start_dt, end_at: end_dt, updated_at: DateTime.utc_now()})
    end
  end

  @doc """
  Cancels an existing appointment and cleans up scheduled reminders.
  """
  @spec cancel(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel(appointment_id, reason \\ "user_cancelled") do
    with {:ok, appointment} <- AppointmentRepo.get(appointment_id),
         {:ok, _} <- AppointmentRepo.update(appointment, %{status: :cancelled, cancel_reason: reason}) do
      ReminderDispatcher.cancel_all(appointment_id)
      :ok
    end
  end

  defp decode_recurrence(nil), do: {:ok, :none}

  defp decode_recurrence(recurrence) when is_binary(recurrence) do
    atom = String.to_atom(recurrence)

    if atom in @valid_recurrences do
      {:ok, atom}
    else
      {:error, {:invalid_recurrence, recurrence}}
    end
  end

  defp decode_recurrence(_), do: {:error, :invalid_recurrence_format}

  defp create_appointment(user, params, start_dt, end_dt, recurrence) do
    AppointmentRepo.insert(%Appointment{
      id: MyApp.UUID.generate(),
      user_id: user.id,
      title: params["title"],
      description: params["description"],
      start_at: start_dt,
      end_at: end_dt,
      recurrence: recurrence,
      location: params["location"],
      status: :scheduled,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp validate_duration(start_dt, end_dt) do
    duration = DateTime.diff(end_dt, start_dt, :minute)

    cond do
      duration <= 0 -> {:error, :end_before_start}
      duration > @max_duration_minutes -> {:error, {:duration_too_long, @max_duration_minutes}}
      true -> :ok
    end
  end

  defp validate_advance_booking(start_dt) do
    max_date = Date.add(Date.utc_today(), @advance_booking_days)

    if Date.compare(DateTime.to_date(start_dt), max_date) == :gt do
      {:error, {:too_far_in_advance, @advance_booking_days}}
    else
      :ok
    end
  end

  defp parse_datetime(nil), do: {:error, :missing_datetime}

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_datetime, str}}
    end
  end
end
```
