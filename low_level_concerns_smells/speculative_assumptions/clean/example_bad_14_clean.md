```elixir
defmodule Scheduling.SlotIdentifierParser do
  @moduledoc """
  Decodes appointment slot identifier strings used by the booking engine.

  Slot identifiers encode the key scheduling dimensions in a compact, URL-safe
  string suitable for use in calendar deep-links and webhook payloads.

  Format:
    "<ISO_DATE>/<HH:MM>/<DURATION_MINUTES>/<RESOURCE_ID>"

  Examples:
    "2024-04-10/09:00/60/consult-room-3"
    "2024-04-10/14:30/30/dr-chen"
    "2024-04-11/08:00/90/procedure-suite-b"
  """

  require Logger

  defstruct [:date, :start_time, :duration_minutes, :resource_id, :raw]

  @min_duration 5
  @max_duration 480

  @doc """
  Decodes a slot identifier string into a `%SlotIdentifierParser{}` struct.

  Returns `{:ok, struct}` on success or `{:error, reason}` if any component
  fails validation.
  """

  def decode(slot_id) when is_binary(slot_id) do
    parts            = String.split(slot_id, "/")
    raw_date         = Enum.at(parts, 0)
    raw_time         = Enum.at(parts, 1)
    raw_duration     = Enum.at(parts, 2)
    resource_id      = Enum.at(parts, 3)

    with {:ok, date}  <- parse_date(raw_date),
         {:ok, time}  <- parse_time(raw_time),
         {:ok, dur}   <- parse_duration(raw_duration) do
      {:ok, %__MODULE__{
        date:             date,
        start_time:       time,
        duration_minutes: dur,
        resource_id:      resource_id,
        raw:              slot_id
      }}
    end
  end

  @doc """
  Encodes a `%SlotIdentifierParser{}` struct back into a canonical slot identifier string.
  """
  def encode(%__MODULE__{date: date, start_time: time, duration_minutes: dur, resource_id: rid}) do
    time_str = time |> Time.to_string() |> String.slice(0, 5)
    "#{Date.to_string(date)}/#{time_str}/#{dur}/#{rid}"
  end

  @doc """
  Returns the end time of an appointment slot.
  """
  def end_time(%__MODULE__{start_time: time, duration_minutes: dur}) do
    Time.add(time, dur * 60, :second)
  end

  @doc """
  Returns true if two slot structs overlap in time on the same resource.
  Used during double-booking checks.
  """
  def overlaps?(%__MODULE__{resource_id: rid, date: d} = a,
                %__MODULE__{resource_id: rid, date: d} = b) do
    a_end = end_time(a)
    b_end = end_time(b)
    Time.compare(a.start_time, b_end) == :lt and
    Time.compare(b.start_time, a_end) == :lt
  end

  def overlaps?(_, _), do: false

  @doc """
  Decodes a list of slot identifiers, partitioning results by success/failure.
  """
  def decode_many(slot_ids) when is_list(slot_ids) do
    Enum.reduce(slot_ids, {[], []}, fn id, {ok_acc, err_acc} ->
      case decode(id) do
        {:ok, slot}      -> {[slot | ok_acc], err_acc}
        {:error, reason} -> {ok_acc, [{id, reason} | err_acc]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_date(nil), do: {:error, :missing_date}

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, date}
      _           -> {:error, {:invalid_date, str}}
    end
  end

  defp parse_time(nil), do: {:error, :missing_time}

  defp parse_time(str) do
    case Time.from_iso8601(str <> ":00") do
      {:ok, time} -> {:ok, time}
      _           -> {:error, {:invalid_time, str}}
    end
  end

  defp parse_duration(nil), do: {:error, :missing_duration}

  defp parse_duration(str) do
    case Integer.parse(str) do
      {n, ""} when n >= @min_duration and n <= @max_duration -> {:ok, n}
      {n, ""}  -> {:error, {:duration_out_of_range, n, @min_duration, @max_duration}}
      _        -> {:error, {:invalid_duration, str}}
    end
  end
end
```
