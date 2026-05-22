```elixir
defmodule MyApp.Scheduling.AppointmentScheduler do
  @moduledoc """
  Manages appointment booking, availability queries, and
  calendar conflict detection for service providers.
  """

  alias MyApp.Repo
  alias MyApp.Scheduling.{Appointment, Availability, Provider}
  import Ecto.Query

  require Logger

  @default_duration_minutes 60
  @buffer_minutes 15

  @doc """
  Lists all providers that have at least one available slot on the given date.

  Returns a list of `%Provider{}` structs.
  """
  def available_providers(%Date{} = date) do
    Provider
    |> join(:inner, [p], a in Availability, on: a.provider_id == p.id)
    |> where([_p, a], a.date == ^date and a.status == :open)
    |> distinct([p, _a], p.id)
    |> Repo.all()
  end

  @doc """
  Returns all open time slots for a provider on a specific date.

  Each slot is a map with `:start_time` and `:end_time` `%Time{}` keys.
  """
  def open_slots(provider_id, %Date{} = date) do
    slots =
      Availability
      |> where([a], a.provider_id == ^provider_id and a.date == ^date and a.status == :open)
      |> Repo.all()
      |> Enum.map(&%{start_time: &1.start_time, end_time: &1.end_time})

    {:ok, slots}
  end

  # Books an appointment slot for a customer with a specific provider.
  #
  # Arguments:
  #   provider_id  - integer ID of the provider performing the service.
  #   customer_id  - integer ID of the customer requesting the appointment.
  #   slot         - map containing :date (%Date{}), :start_time (%Time{}),
  #                  and optionally :duration_minutes (integer, default @default_duration_minutes).
  #
  # Checks that:
  #   1. The requested slot falls within an open Availability window.
  #   2. There are no conflicting Appointment records for the provider
  #      in the slot window (plus the @buffer_minutes buffer).
  #
  # On success, marks the Availability record as :booked and inserts a new
  # Appointment with status :confirmed.
  #
  # Returns {:ok, appointment} or {:error, reason}.
  def book_slot(provider_id, customer_id, slot) do
    duration = Map.get(slot, :duration_minutes, @default_duration_minutes)
    end_time = Time.add(slot.start_time, duration * 60, :second)

    with {:ok, availability} <- find_open_availability(provider_id, slot.date, slot.start_time, end_time),
         :ok <- check_conflicts(provider_id, slot.date, slot.start_time, end_time) do
      Repo.transaction(fn ->
        {:ok, _} =
          availability
          |> Availability.changeset(%{status: :booked})
          |> Repo.update()

        {:ok, appointment} =
          Appointment.changeset(%Appointment{}, %{
            provider_id: provider_id,
            customer_id: customer_id,
            date: slot.date,
            start_time: slot.start_time,
            end_time: end_time,
            duration_minutes: duration,
            status: :confirmed
          })
          |> Repo.insert()

        Logger.info("Appointment booked",
          appointment_id: appointment.id,
          provider_id: provider_id,
          customer_id: customer_id
        )

        appointment
      end)
    end
  end

  @doc """
  Cancels an existing confirmed appointment.

  Returns `{:ok, appointment}` with status `:cancelled`, or `{:error, reason}`.
  """
  def cancel(appointment_id, reason \\ nil) do
    with {:ok, appointment} <- fetch_confirmed(appointment_id) do
      Repo.transaction(fn ->
        {:ok, cancelled} =
          appointment
          |> Appointment.changeset(%{status: :cancelled, cancellation_reason: reason})
          |> Repo.update()

        Availability
        |> where([a], a.provider_id == ^appointment.provider_id
                   and a.date == ^appointment.date
                   and a.start_time == ^appointment.start_time)
        |> Repo.update_all(set: [status: :open])

        cancelled
      end)
    end
  end

  # --- Private helpers ---

  defp find_open_availability(provider_id, date, start_time, end_time) do
    query =
      Availability
      |> where([a], a.provider_id == ^provider_id and a.date == ^date)
      |> where([a], a.start_time <= ^start_time and a.end_time >= ^end_time)
      |> where([a], a.status == :open)

    case Repo.one(query) do
      nil -> {:error, :slot_not_available}
      av -> {:ok, av}
    end
  end

  defp check_conflicts(provider_id, date, start_time, end_time) do
    buffered_start = Time.add(start_time, -@buffer_minutes * 60, :second)
    buffered_end = Time.add(end_time, @buffer_minutes * 60, :second)

    conflict =
      Appointment
      |> where([a], a.provider_id == ^provider_id and a.date == ^date and a.status == :confirmed)
      |> where([a], a.start_time < ^buffered_end and a.end_time > ^buffered_start)
      |> Repo.exists?()

    if conflict, do: {:error, :time_conflict}, else: :ok
  end

  defp fetch_confirmed(id) do
    case Repo.get(Appointment, id) do
      %Appointment{status: :confirmed} = a -> {:ok, a}
      nil -> {:error, :not_found}
      _ -> {:error, :not_confirmable}
    end
  end
end
```
