```elixir
defmodule Scheduling.InputParser do
  @moduledoc """
  Parses and normalises raw string inputs received from API requests
  in the scheduling context, including dates, times, and durations.
  """

  defmacro parse_iso_date(raw_string) do
    quote do
      case Date.from_iso8601(unquote(raw_string)) do
        {:ok, date} -> {:ok, date}
        {:error, _} -> {:error, "Invalid date format; expected YYYY-MM-DD, got: #{unquote(raw_string)}"}
      end
    end
  end

  @doc """
  Parses a time string in HH:MM format into a `Time` struct.
  """
  @spec parse_time(String.t()) :: {:ok, Time.t()} | {:error, String.t()}
  def parse_time(raw) when is_binary(raw) do
    case Time.from_iso8601("#{raw}:00") do
      {:ok, time} -> {:ok, time}
      {:error, _} -> {:error, "Invalid time format; expected HH:MM, got: #{raw}"}
    end
  end

  @doc """
  Parses a duration string in the format "Xh Ym" (e.g. "1h 30m") into minutes.
  """
  @spec parse_duration_minutes(String.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  def parse_duration_minutes(raw) when is_binary(raw) do
    case Regex.run(~r/^(?:(\d+)h)?\s*(?:(\d+)m)?$/, String.trim(raw), capture: :all_but_first) do
      [hours_str, minutes_str] ->
        hours = if hours_str == "", do: 0, else: String.to_integer(hours_str)
        minutes = if minutes_str == "", do: 0, else: String.to_integer(minutes_str)
        total = hours * 60 + minutes

        if total > 0, do: {:ok, total}, else: {:error, "Duration must be positive"}

      _ ->
        {:error, "Invalid duration format; expected e.g. '1h 30m', got: #{raw}"}
    end
  end

  @doc """
  Parses a recurrence rule atom from a string input.
  """
  @spec parse_recurrence(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def parse_recurrence(raw) when is_binary(raw) do
    valid = ~w(none daily weekly biweekly monthly)

    if raw in valid do
      {:ok, String.to_atom(raw)}
    else
      {:error, "Invalid recurrence '#{raw}'; must be one of: #{Enum.join(valid, ", ")}"}
    end
  end
end

defmodule Scheduling.AppointmentRequestHandler do
  @moduledoc """
  Handles raw API request payloads for appointment creation,
  parsing and validating all input fields before passing to the booking service.
  """

  require Scheduling.InputParser

  alias Scheduling.InputParser

  @doc """
  Parses and validates an appointment creation request map.
  Returns `{:ok, parsed}` with normalised fields or `{:error, errors}`.
  """
  @spec parse_request(map()) :: {:ok, map()} | {:error, map()}
  def parse_request(params) do
    results = %{
      date: InputParser.parse_iso_date(Map.get(params, "date", "")),
      start_time: InputParser.parse_time(Map.get(params, "start_time", "")),
      duration: InputParser.parse_duration_minutes(Map.get(params, "duration", "")),
      recurrence: InputParser.parse_recurrence(Map.get(params, "recurrence", "none"))
    }

    errors =
      results
      |> Enum.filter(fn {_, v} -> match?({:error, _}, v) end)
      |> Map.new(fn {k, {:error, msg}} -> {k, msg} end)

    if map_size(errors) > 0 do
      {:error, errors}
    else
      parsed = Map.new(results, fn {k, {:ok, v}} -> {k, v} end)

      {:ok,
       Map.merge(parsed, %{
         practitioner_id: Map.get(params, "practitioner_id"),
         patient_id: Map.get(params, "patient_id"),
         notes: Map.get(params, "notes", "")
       })}
    end
  end

  @doc """
  Validates that the practitioner and patient IDs are non-empty strings.
  """
  @spec validate_participants(map()) :: :ok | {:error, String.t()}
  def validate_participants(%{practitioner_id: pid, patient_id: patient_id}) do
    cond do
      not is_binary(pid) or String.trim(pid) == "" ->
        {:error, "practitioner_id is required"}

      not is_binary(patient_id) or String.trim(patient_id) == "" ->
        {:error, "patient_id is required"}

      true ->
        :ok
    end
  end
end
```
