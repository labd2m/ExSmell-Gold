```elixir
defmodule Scheduling.ICalExporter do
  @moduledoc """
  Exports scheduling events to iCalendar (.ics) format as defined by
  RFC 5545. The output can be served directly to calendar clients
  (Google Calendar, Apple Calendar, Outlook) or written to disk for
  bulk import.

  Each `Event` struct must carry at least: `uid`, `summary`,
  `dtstart`, `dtend`, `organizer_email`, and `status`.
  """

  alias Scheduling.Event

  @ical_line_length 75
  @crlf "\r\n"
  @product_id "-//MyApp//Scheduler//EN"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Converts a list of `Event` structs into an iCalendar binary.
  Returns `{:ok, ics_binary}` or `{:error, reason}`.
  """
  def export(events) when is_list(events) do
    components =
      events
      |> Enum.map(&render_event/1)
      |> Enum.join(@crlf)

    ics = wrap_vcalendar(components)
    {:ok, ics}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Exports a single event to its iCalendar VEVENT block."
  def export_single(%Event{} = event) do
    {:ok, render_event(event)}
  end

  # ---------------------------------------------------------------------------
  # Event rendering
  # ---------------------------------------------------------------------------

  defp render_event(%Event{} = event) do
    fields = [
      {"UID", event.uid},
      {"SUMMARY", escape_text(event.summary)},
      {"DTSTART", format_datetime(event.dtstart)},
      {"DTEND", format_datetime(event.dtend)},
      {"ORGANIZER", "MAILTO:#{event.organizer_email}"},
      {"STATUS", render_status(event.status)},
      {"DESCRIPTION", escape_text(event.description || "")},
      {"LOCATION", escape_text(event.location || "")}
    ]

    lines =
      fields
      |> Enum.reject(fn {_, v} -> v == "" end)
      |> Enum.map(fn {name, value} ->
        render_property(name, value)
      end)

    Enum.join(["BEGIN:VEVENT" | lines] ++ ["END:VEVENT"], @crlf)
  end

  defp render_property(name, value) do
    line = "#{name}:#{format_field_value(value)}"
    fold_line(line)
  end

  defp render_status(:confirmed), do: "CONFIRMED"
  defp render_status(:tentative),  do: "TENTATIVE"
  defp render_status(:cancelled),  do: "CANCELLED"
  defp render_status(other) when is_binary(other), do: String.upcase(other)

  defp format_field_value(value) do
    to_string(value)
  end

  # ---------------------------------------------------------------------------
  # iCalendar formatting helpers
  # ---------------------------------------------------------------------------

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y%m%dT%H%M%S")
  end

  defp escape_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp fold_line(line) when is_binary(line) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(@ical_line_length)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(@crlf <> " ")
  end

  defp wrap_vcalendar(components) do
    """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:#{@product_id}\r
    CALSCALE:GREGORIAN\r
    METHOD:PUBLISH\r
    #{components}\r
    END:VCALENDAR\r
    """
  end
end
```
