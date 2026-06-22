```elixir
defmodule Scheduling.TimeSlot do
  @moduledoc """
  An immutable time slot anchored to a specific IANA timezone.
  All comparisons and duration calculations are performed in UTC
  internally while preserving the display timezone for rendering.
  """

  @enforce_keys [:starts_at_utc, :ends_at_utc, :timezone]
  defstruct [:starts_at_utc, :ends_at_utc, :timezone]

  @type t :: %__MODULE__{
          starts_at_utc: DateTime.t(),
          ends_at_utc: DateTime.t(),
          timezone: String.t()
        }

  @spec new(DateTime.t(), DateTime.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def new(%DateTime{} = starts_at, %DateTime{} = ends_at, timezone)
      when is_binary(timezone) do
    with :ok <- validate_order(starts_at, ends_at),
         {:ok, _} <- validate_timezone(timezone) do
      {:ok,
       %__MODULE__{
         starts_at_utc: DateTime.shift_zone!(starts_at, "Etc/UTC"),
         ends_at_utc: DateTime.shift_zone!(ends_at, "Etc/UTC"),
         timezone: timezone
       }}
    end
  end

  @spec duration_minutes(t()) :: pos_integer()
  def duration_minutes(%__MODULE__{starts_at_utc: s, ends_at_utc: e}) do
    div(DateTime.diff(e, s, :second), 60)
  end

  @spec overlaps?(t(), t()) :: boolean()
  def overlaps?(%__MODULE__{} = a, %__MODULE__{} = b) do
    DateTime.compare(a.starts_at_utc, b.ends_at_utc) == :lt and
      DateTime.compare(b.starts_at_utc, a.ends_at_utc) == :lt
  end

  @spec contains?(t(), DateTime.t()) :: boolean()
  def contains?(%__MODULE__{starts_at_utc: s, ends_at_utc: e}, %DateTime{} = point) do
    utc = DateTime.shift_zone!(point, "Etc/UTC")
    DateTime.compare(utc, s) in [:gt, :eq] and DateTime.compare(utc, e) == :lt
  end

  @spec local_start(t()) :: DateTime.t()
  def local_start(%__MODULE__{starts_at_utc: s, timezone: tz}) do
    DateTime.shift_zone!(s, tz)
  end

  @spec local_end(t()) :: DateTime.t()
  def local_end(%__MODULE__{ends_at_utc: e, timezone: tz}) do
    DateTime.shift_zone!(e, tz)
  end

  defp validate_order(starts_at, ends_at) do
    if DateTime.compare(starts_at, ends_at) == :lt, do: :ok, else: {:error, :invalid_slot_order}
  end

  defp validate_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, _} -> {:ok, tz}
      {:error, _} -> {:error, :unknown_timezone}
    end
  end
end

defmodule Scheduling.Availability do
  @moduledoc """
  Computes available time slots from a set of working windows after removing
  blocked intervals. All slot arithmetic is performed in UTC.
  """

  alias Scheduling.TimeSlot

  @type window :: %{from: DateTime.t(), to: DateTime.t()}

  @spec free_slots(list(TimeSlot.t()), list(TimeSlot.t()), pos_integer(), String.t()) ::
          list(TimeSlot.t())
  def free_slots(working_windows, blocked_slots, slot_duration_minutes, timezone)
      when is_list(working_windows) and is_list(blocked_slots) and
             is_integer(slot_duration_minutes) and slot_duration_minutes > 0 do
    working_windows
    |> Enum.flat_map(&generate_slots(&1, slot_duration_minutes, timezone))
    |> Enum.reject(fn slot -> Enum.any?(blocked_slots, &TimeSlot.overlaps?(slot, &1)) end)
  end

  defp generate_slots(%TimeSlot{} = window, duration_minutes, timezone) do
    step_seconds = duration_minutes * 60
    duration_seconds = step_seconds

    Stream.iterate(window.starts_at_utc, &DateTime.add(&1, step_seconds, :second))
    |> Stream.take_while(fn start ->
      finish = DateTime.add(start, duration_seconds, :second)
      DateTime.compare(finish, window.ends_at_utc) in [:lt, :eq]
    end)
    |> Enum.flat_map(fn start ->
      finish = DateTime.add(start, duration_seconds, :second)
      case TimeSlot.new(start, finish, timezone) do
        {:ok, slot} -> [slot]
        {:error, _} -> []
      end
    end)
  end
end
```
