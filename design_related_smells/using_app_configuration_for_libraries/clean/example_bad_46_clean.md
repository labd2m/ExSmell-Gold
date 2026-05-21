```elixir
defmodule DateTimeFormatter do
  @moduledoc """
  A library for formatting `DateTime`, `NaiveDateTime`, and Unix timestamps
  into human-readable strings for use in emails, reports, and API responses.

  Configuration (config/config.exs):

      config :datetime_formatter,
        timezone: "America/New_York",
        date_format: :iso8601
  """

  @supported_formats [:iso8601, :rfc2822, :human_short, :human_long, :date_only, :time_only]

  @month_names ~w(January February March April May June July August September October November December)
  @day_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @doc """
  Formats a `DateTime`, `NaiveDateTime`, or Unix integer timestamp into a
  string using the globally configured timezone and format.
  """
  @spec format(DateTime.t() | NaiveDateTime.t() | integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def format(dt) do
    timezone = Application.fetch_env!(:datetime_formatter, :timezone)
    date_format = Application.fetch_env!(:datetime_formatter, :date_format)

    with {:ok, utc_dt} <- to_utc_datetime(dt),
         {:ok, local_dt} <- shift_timezone(utc_dt, timezone) do
      render(local_dt, date_format)
    end
  end

  @doc """
  Returns a relative time string like "2 hours ago" or "in 3 days".
  The reference point is adjusted to the configured timezone.
  """
  @spec format_relative(DateTime.t() | NaiveDateTime.t() | integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def format_relative(dt) do
    timezone = Application.fetch_env!(:datetime_formatter, :timezone)

    with {:ok, utc_dt} <- to_utc_datetime(dt),
         {:ok, _local_dt} <- shift_timezone(utc_dt, timezone) do
      now = DateTime.utc_now()
      diff_seconds = DateTime.diff(now, utc_dt)
      {:ok, humanize_diff(diff_seconds)}
    end
  end

  @doc """
  Parses an ISO8601 string into a `DateTime`. Returns `{:ok, dt}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def parse(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, "Could not parse '#{iso_string}': #{inspect(reason)}"}
    end
  end

  @doc """
  Returns the start and end of the calendar day in UTC for a given local date string.
  """
  @spec day_bounds(String.t()) :: {:ok, {DateTime.t(), DateTime.t()}} | {:error, String.t()}
  def day_bounds(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        start_of_day = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
        end_of_day = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        {:ok, {start_of_day, end_of_day}}

      {:error, reason} ->
        {:error, "Invalid date string '#{date_string}': #{inspect(reason)}"}
    end
  end

  # --- Private helpers ---

  defp to_utc_datetime(%DateTime{} = dt), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

  defp to_utc_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, "Invalid Unix timestamp: #{unix}"}
    end
  end

  defp shift_timezone(dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local_dt} -> {:ok, local_dt}
      {:error, _} -> {:error, "Unknown timezone: #{tz}"}
    end
  end

  defp render(dt, :iso8601), do: {:ok, DateTime.to_iso8601(dt)}

  defp render(dt, :date_only) do
    {:ok, "#{pad(dt.year, 4)}-#{pad(dt.month, 2)}-#{pad(dt.day, 2)}"}
  end

  defp render(dt, :time_only) do
    {:ok, "#{pad(dt.hour, 2)}:#{pad(dt.minute, 2)}:#{pad(dt.second, 2)}"}
  end

  defp render(dt, :human_short) do
    month = Enum.at(@month_names, dt.month - 1)
    {:ok, "#{month} #{dt.day}, #{dt.year}"}
  end

  defp render(dt, :human_long) do
    dow = day_of_week_name(dt)
    month = Enum.at(@month_names, dt.month - 1)
    {:ok, "#{dow}, #{month} #{dt.day}, #{dt.year} at #{pad(dt.hour, 2)}:#{pad(dt.minute, 2)}"}
  end

  defp render(dt, :rfc2822) do
    {:ok, Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S %z")}
  end

  defp render(_, fmt), do: {:error, "Unsupported format: #{inspect(fmt)}"}

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width, "0")

  defp day_of_week_name(dt) do
    Enum.at(@day_names, Calendar.ISO.day_of_week(dt.year, dt.month, dt.day, :monday) - 1)
  end

  defp humanize_diff(seconds) when seconds < 0, do: "in #{humanize_diff(-seconds)}"
  defp humanize_diff(seconds) when seconds < 60, do: "just now"
  defp humanize_diff(seconds) when seconds < 3600, do: "#{div(seconds, 60)} minutes ago"
  defp humanize_diff(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)} hours ago"
  defp humanize_diff(seconds), do: "#{div(seconds, 86_400)} days ago"
end
```
