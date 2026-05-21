```elixir
defmodule SlotRegistry do
  @moduledoc """
  Manages appointment slot availability and bookings for the scheduling subsystem.
  Operates as an Agent holding in-memory slot state.
  """

  use Agent

  defmodule SlotUnavailableError do
    defexception [:message, :slot_id, :requested_at]

    @impl true
    def exception(opts) do
      slot_id = Keyword.fetch!(opts, :slot_id)
      %__MODULE__{
        message: "Slot #{slot_id} is no longer available",
        slot_id: slot_id,
        requested_at: DateTime.utc_now()
      }
    end
  end

  defmodule SlotNotFoundError do
    defexception [:message, :slot_id]

    @impl true
    def exception(opts) do
      slot_id = Keyword.fetch!(opts, :slot_id)
      %__MODULE__{
        message: "Slot #{slot_id} does not exist in the registry",
        slot_id: slot_id
      }
    end
  end

  def start_link(slots) do
    Agent.start_link(fn -> slots end, name: __MODULE__)
  end

  def list_available do
    Agent.get(__MODULE__, fn slots ->
      Enum.filter(slots, fn {_id, slot} -> slot.status == :available end)
      |> Enum.map(fn {id, slot} -> Map.put(slot, :id, id) end)
    end)
  end

  def book!(slot_id, patient_id, notes \\ "") do
    slot =
      Agent.get(__MODULE__, fn slots -> Map.get(slots, slot_id) end)

    if is_nil(slot) do
      raise SlotNotFoundError, slot_id: slot_id
    end

    if slot.status != :available do
      raise SlotUnavailableError, slot_id: slot_id
    end

    booking_ref = generate_ref()

    Agent.update(__MODULE__, fn slots ->
      Map.update!(slots, slot_id, fn s ->
        %{
          s
          | status: :booked,
            patient_id: patient_id,
            booking_ref: booking_ref,
            notes: notes,
            booked_at: DateTime.utc_now()
        }
      end)
    end)

    %{
      booking_ref: booking_ref,
      slot_id: slot_id,
      patient_id: patient_id,
      scheduled_at: slot.scheduled_at,
      duration_minutes: slot.duration_minutes,
      provider: slot.provider,
      notes: notes
    }
  end

  def cancel(slot_id) do
    Agent.update(__MODULE__, fn slots ->
      Map.update(slots, slot_id, slots[slot_id], fn s ->
        %{s | status: :available, patient_id: nil, booking_ref: nil, booked_at: nil}
      end)
    end)

    :ok
  end

  defp generate_ref do
    "BK-" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :upper))
  end
end

defmodule AppointmentService do
  @moduledoc """
  Orchestrates appointment creation including slot booking, confirmation
  messaging, and calendar event generation.
  """

  require Logger

  alias SlotRegistry
  alias SlotRegistry.{SlotUnavailableError, SlotNotFoundError}

  def create_appointment(slot_id, patient, opts \\ []) do
    notes = Keyword.get(opts, :notes, "")

    Logger.info(
      "Attempting to book slot #{slot_id} for patient #{patient.id}"
    )

    # Forced to use try/rescue because SlotRegistry.book!/3 raises exceptions
    # instead of returning tagged tuples.
    try do
      booking = SlotRegistry.book!(slot_id, patient.id, notes)

      confirmation = %{
        booking_ref: booking.booking_ref,
        patient_name: patient.name,
        scheduled_at: booking.scheduled_at,
        duration_minutes: booking.duration_minutes,
        provider: booking.provider,
        instructions: "Please arrive 10 minutes early."
      }

      Logger.info("Booking confirmed: #{booking.booking_ref} for patient #{patient.id}")
      {:ok, confirmation}
    rescue
      e in SlotUnavailableError ->
        Logger.info("Slot #{slot_id} unavailable for patient #{patient.id}: #{e.message}")
        {:error, {:slot_unavailable, e.message}}

      e in SlotNotFoundError ->
        Logger.warning("Unknown slot #{slot_id} requested by patient #{patient.id}: #{e.message}")
        {:error, {:slot_not_found, e.message}}
    end
  end

  def suggest_alternatives(preferred_slot_id, patient_id) do
    available = SlotRegistry.list_available()

    alternatives =
      Enum.reject(available, &(&1.id == preferred_slot_id))
      |> Enum.take(3)

    Logger.info(
      "Suggested #{length(alternatives)} alternatives for patient #{patient_id}"
    )

    alternatives
  end
end
```
