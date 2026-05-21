# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Scheduling.SlotBooker.book/3`
- **Affected function(s):** `Scheduling.SlotBooker.book/3` (library side); `Scheduling.BookingController.handle_request/1` (client side)
- **Explanation:** `book/3` raises `RuntimeError` for expected booking outcomes: a slot in the past, a conflict with an existing booking, and a non-existent resource. Callers trying to book an appointment need to handle these as normal data — they may wish to suggest an alternative slot rather than crashing. Forcing `try/rescue` removes that freedom.

```elixir
defmodule Scheduling.TimeSlot do
  @moduledoc "Represents a bookable time window for a given resource."

  @enforce_keys [:resource_id, :start_at, :end_at]
  defstruct [:resource_id, :start_at, :end_at, :metadata]

  def duration_minutes(%__MODULE__{start_at: s, end_at: e}) do
    DateTime.diff(e, s, :second) |> div(60)
  end

  def overlaps?(%__MODULE__{start_at: s1, end_at: e1}, %__MODULE__{start_at: s2, end_at: e2}) do
    DateTime.compare(s1, e2) == :lt and DateTime.compare(e1, s2) == :gt
  end
end

defmodule Scheduling.ResourceRegistry do
  @moduledoc "Holds the catalogue of bookable resources (rooms, staff, equipment)."

  @resources %{
    "room-101" => %{id: "room-101", name: "Conference Room A", capacity: 20},
    "room-102" => %{id: "room-102", name: "Conference Room B", capacity: 10},
    "staff-dr-jones" => %{id: "staff-dr-jones", name: "Dr. Jones", role: :physician}
  }

  def find(id), do: Map.fetch(@resources, id)
  def all, do: Map.values(@resources)
end

defmodule Scheduling.BookingStore do
  @moduledoc "In-memory booking ledger."

  use Agent

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def all, do: Agent.get(__MODULE__, & &1)

  def add(booking), do: Agent.update(__MODULE__, &[booking | &1])

  def for_resource(resource_id) do
    Agent.get(__MODULE__, fn bookings ->
      Enum.filter(bookings, &(&1.resource_id == resource_id))
    end)
  end
end

defmodule Scheduling.Booking do
  @moduledoc "Confirmed booking record."

  @enforce_keys [:id, :resource_id, :attendee, :slot, :booked_at]
  defstruct [:id, :resource_id, :attendee, :slot, :booked_at, :notes]
end

defmodule Scheduling.SlotBooker do
  @moduledoc """
  Creates confirmed bookings for a given resource and time slot.
  Validates availability, resource existence, and slot timing before persisting.
  """

  alias Scheduling.{Booking, BookingStore, ResourceRegistry, TimeSlot}
  require Logger

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `book/3` raises RuntimeError for three
  # VALIDATION: common, expected booking failure conditions: booking a past slot,
  # VALIDATION: a scheduling conflict, and an unknown resource. In an interactive
  # VALIDATION: booking UI, none of these is a crash scenario — they are user-facing
  # VALIDATION: validation messages. Callers are denied the ability to pattern-match
  # VALIDATION: on {:error, reason} and must rely on try/rescue instead.
  def book(%TimeSlot{} = slot, attendee, opts \\ []) when is_binary(attendee) do
    now = DateTime.utc_now()

    if DateTime.compare(slot.start_at, now) != :gt do
      raise RuntimeError,
        message: "Cannot book a slot that starts in the past (#{slot.start_at})"
    end

    case ResourceRegistry.find(slot.resource_id) do
      :error ->
        raise RuntimeError,
          message: "Resource '#{slot.resource_id}' does not exist in the registry"

      {:ok, resource} ->
        conflicts =
          BookingStore.for_resource(slot.resource_id)
          |> Enum.filter(fn existing ->
            TimeSlot.overlaps?(slot, existing.slot)
          end)

        unless Enum.empty?(conflicts) do
          conflict = hd(conflicts)

          raise RuntimeError,
            message:
              "Time slot conflicts with existing booking ##{conflict.id} " <>
                "for resource '#{resource.name}' at #{conflict.slot.start_at}"
        end

        notes = Keyword.get(opts, :notes, nil)

        booking = %Booking{
          id: "bkg_#{:rand.uniform(999_999)}",
          resource_id: slot.resource_id,
          attendee: attendee,
          slot: slot,
          booked_at: now,
          notes: notes
        }

        BookingStore.add(booking)
        Logger.info("Booking #{booking.id} created for #{attendee} on #{slot.resource_id}")
        booking
    end
  end
  # VALIDATION: SMELL END

  def cancel(booking_id) when is_binary(booking_id) do
    Logger.info("Booking #{booking_id} cancelled")
    :ok
  end
end

defmodule Scheduling.BookingController do
  @moduledoc """
  Handles incoming appointment booking requests from the web layer.
  Translates domain outcomes into HTTP-friendly response tuples.
  """

  alias Scheduling.{SlotBooker, TimeSlot}
  require Logger

  def handle_request(%{resource_id: rid, attendee: attendee, start_at: start_at, end_at: end_at}) do
    slot = %TimeSlot{resource_id: rid, start_at: start_at, end_at: end_at}

    # Client forced to use try/rescue because SlotBooker.book/3
    # raises on all failure paths instead of returning {:error, reason}.
    try do
      booking = SlotBooker.book(slot, attendee)

      %{
        status: 201,
        body: %{booking_id: booking.id, resource: rid, attendee: attendee}
      }
    rescue
      e in RuntimeError ->
        Logger.warning("Booking request rejected for #{attendee}: #{e.message}")

        %{
          status: 422,
          body: %{error: e.message}
        }
    end
  end
end
```
