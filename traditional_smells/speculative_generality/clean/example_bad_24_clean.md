```elixir
defmodule Scheduling.RecurrenceParser do
  @moduledoc """
  Parses iCalendar RRULE strings into structured recurrence maps.

  Supports FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, and WKST fields.
  """

  @supported_freqs ~w(DAILY WEEKLY MONTHLY YEARLY)
  @day_map %{
    "MO" => :monday, "TU" => :tuesday, "WE" => :wednesday,
    "TH" => :thursday, "FR" => :friday, "SA" => :saturday, "SU" => :sunday
  }

  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse("RRULE:" <> rule_string) do
    parse(rule_string)
  end

  def parse(rule_string) when is_binary(rule_string) do
    parts = String.split(rule_string, ";")

    result =
      Enum.reduce_while(parts, %{}, fn part, acc ->
        case parse_part(part) do
          {:ok, key, value} -> {:cont, Map.put(acc, key, value)}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      map when is_map(map) -> validate_recurrence(map)
    end
  end

  def parse(_), do: {:error, "RRULE must be a string"}

  defp parse_part("FREQ=" <> freq) when freq in @supported_freqs do
    {:ok, :freq, String.downcase(freq) |> String.to_atom()}
  end

  defp parse_part("FREQ=" <> freq), do: {:error, "Unsupported FREQ: #{freq}"}

  defp parse_part("INTERVAL=" <> n) do
    case Integer.parse(n) do
      {val, ""} when val > 0 -> {:ok, :interval, val}
      _ -> {:error, "Invalid INTERVAL: #{n}"}
    end
  end

  defp parse_part("COUNT=" <> n) do
    case Integer.parse(n) do
      {val, ""} when val > 0 -> {:ok, :count, val}
      _ -> {:error, "Invalid COUNT: #{n}"}
    end
  end

  defp parse_part("BYDAY=" <> days) do
    parsed =
      days
      |> String.split(",")
      |> Enum.map(&Map.get(@day_map, &1))

    if Enum.all?(parsed) do
      {:ok, :byday, parsed}
    else
      {:error, "Invalid BYDAY value: #{days}"}
    end
  end

  defp parse_part("WKST=" <> day) do
    case Map.get(@day_map, day) do
      nil -> {:error, "Invalid WKST: #{day}"}
      atom -> {:ok, :wkst, atom}
    end
  end

  defp parse_part(_part), do: {:ok, :unknown, nil}

  defp validate_recurrence(%{freq: _} = map), do: {:ok, map}
  defp validate_recurrence(_), do: {:error, "FREQ is required"}
end

defmodule Scheduling.AppointmentScheduler do
  @moduledoc """
  Creates, updates, and cancels appointments for service providers.
  """

  alias Scheduling.{Appointment, AvailabilityChecker, NotificationSender}

  require Logger

  @default_duration_minutes 60

  @spec schedule(map()) :: {:ok, Appointment.t()} | {:error, atom()}
  def schedule(%{provider_id: provider_id, starts_at: starts_at} = params) do
    duration = Map.get(params, :duration_minutes, @default_duration_minutes)
    ends_at = DateTime.add(starts_at, duration * 60, :second)

    with :ok <- AvailabilityChecker.check(provider_id, starts_at, ends_at),
         {:ok, appt} <- Appointment.create(Map.put(params, :ends_at, ends_at)),
         :ok <- NotificationSender.send_confirmation(appt) do
      Logger.info("Appointment created id=#{appt.id} provider=#{provider_id}")
      {:ok, appt}
    end
  end

  @spec cancel(String.t(), String.t()) :: {:ok, Appointment.t()} | {:error, atom()}
  def cancel(appointment_id, reason) do
    with {:ok, appt} <- Appointment.fetch(appointment_id),
         {:ok, cancelled} <- Appointment.cancel(appt, reason),
         :ok <- NotificationSender.send_cancellation(cancelled) do
      {:ok, cancelled}
    end
  end
end
```
