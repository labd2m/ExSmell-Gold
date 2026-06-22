```elixir
defmodule Platform.TimeZone do
  @moduledoc """
  Pure-function utilities for time zone conversion, business hours evaluation,
  and human-readable datetime formatting across geographic regions.

  All functions accept explicit time zone strings (IANA format) rather than
  relying on system defaults, making them safe for multi-tenant applications
  where different accounts operate in different time zones.
  """

  @type tz :: String.t()
  @type business_hours :: %{open: Time.t(), close: Time.t(), days: [1..7]}

  @default_business_hours %{
    open: ~T[09:00:00],
    close: ~T[17:00:00],
    days: [1, 2, 3, 4, 5]
  }

  @doc """
  Converts a `DateTime` from its current time zone to `target_tz`.
  Returns `{:ok, datetime}` or `{:error, :invalid_timezone}`.
  """
  @spec convert(DateTime.t(), tz()) :: {:ok, DateTime.t()} | {:error, :invalid_timezone}
  def convert(%DateTime{} = dt, target_tz) when is_binary(target_tz) do
    case DateTime.shift_zone(dt, target_tz) do
      {:ok, converted} -> {:ok, converted}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  @doc """
  Returns the current time in `tz`.
  """
  @spec now(tz()) :: {:ok, DateTime.t()} | {:error, :invalid_timezone}
  def now(tz) when is_binary(tz) do
    convert(DateTime.utc_now(), tz)
  end

  @doc """
  Returns `true` if `datetime` falls within business hours in `tz`.
  """
  @spec within_business_hours?(DateTime.t(), tz(), business_hours()) :: boolean()
  def within_business_hours?(%DateTime{} = dt, tz, hours \\ @default_business_hours) do
    case convert(dt, tz) do
      {:ok, local} ->
        day_of_week = Date.day_of_week(DateTime.to_date(local))
        local_time = DateTime.to_time(local)

        day_of_week in hours.days and
          Time.compare(local_time, hours.open) in [:gt, :eq] and
          Time.compare(local_time, hours.close) == :lt

      {:error, _} ->
        false
    end
  end

  @doc """
  Returns the UTC offset string for `tz` at the moment represented by `dt`,
  accounting for DST. Example: `"+05:30"`, `"-08:00"`.
  """
  @spec utc_offset_string(DateTime.t(), tz()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def utc_offset_string(%DateTime{} = dt, tz) do
    case convert(dt, tz) do
      {:ok, local} ->
        total_seconds = local.utc_offset + local.std_offset
        sign = if total_seconds >= 0, do: "+", else: "-"
        abs_seconds = abs(total_seconds)
        hours = div(abs_seconds, 3600)
        minutes = div(rem(abs_seconds, 3600), 60)
        {:ok, "#{sign}#{pad(hours)}:#{pad(minutes)}"}

      err ->
        err
    end
  end

  @doc """
  Formats `datetime` in `tz` as a human-readable string.
  Example: `"Mon, 12 Jan 2026 14:30:00 +05:30"`.
  """
  @spec format(DateTime.t(), tz(), String.t()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def format(%DateTime{} = dt, tz, pattern \\ "%a, %d %b %Y %H:%M:%S %z") do
    case convert(dt, tz) do
      {:ok, local} -> {:ok, Calendar.strftime(local, pattern)}
      err -> err
    end
  end

  @doc """
  Computes the start of the current business day in `tz`.
  Returns midnight if `tz` is invalid.
  """
  @spec start_of_day(DateTime.t(), tz()) :: {:ok, DateTime.t()} | {:error, :invalid_timezone}
  def start_of_day(%DateTime{} = dt, tz) do
    with {:ok, local} <- convert(dt, tz) do
      date = DateTime.to_date(local)
      naive = NaiveDateTime.new!(date, ~T[00:00:00])
      case DateTime.from_naive(naive, tz) do
        {:ok, sod} -> {:ok, sod}
        {:gap, just_before, _just_after} -> {:ok, just_before}
        {:ambiguous, first, _second} -> {:ok, first}
      end
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)
end
```
