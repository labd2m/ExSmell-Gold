# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Scheduling.ICalExporter.format_field_value/1`
- **Affected function(s):** `format_field_value/1`
- **Short explanation:** `format_field_value/1` calls `to_string/1` on any iCalendar field value
  without guard clauses. The function is expected to handle strings, atoms, and integers.
  However, `DateTime` structs implement `String.Chars` and produce their native Elixir
  representation (e.g., `"2024-03-15 09:00:00Z"`) instead of the iCalendar-required format
  (`"20240315T090000Z"`), silently generating RFC 5545-non-compliant `.ics` files that are
  rejected by calendar clients. Passing a `List` (e.g., multi-value attendee field) raises
  `Protocol.UndefinedError`, aborting the export.

---

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

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because format_field_value/1 calls to_string/1
  # VALIDATION: on any iCalendar property value without a guard clause or pattern
  # VALIDATION: match. The function is called with strings, atoms, and pre-formatted
  # VALIDATION: date strings. In practice:
  # VALIDATION: - A DateTime struct implements String.Chars via the Calendar
  # VALIDATION:   protocol and is coerced to "2024-03-15 09:00:00Z", which is
  # VALIDATION:   not the iCalendar DTSTART format ("20240315T090000Z"). The
  # VALIDATION:   caller in render_property/2 passes the result of
  # VALIDATION:   format_datetime/1, which might itself return a DateTime if
  # VALIDATION:   the formatting step is skipped. The resulting .ics file is
  # VALIDATION:   silently non-compliant and rejected by calendar clients.
  # VALIDATION: - A List passed as a property value (e.g., multi-attendee field)
  # VALIDATION:   raises Protocol.UndefinedError, aborting the entire export/1
  # VALIDATION:   call and leaving the caller with a generic error message.
  defp format_field_value(value) do
    to_string(value)
  end
  # VALIDATION: SMELL END

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
