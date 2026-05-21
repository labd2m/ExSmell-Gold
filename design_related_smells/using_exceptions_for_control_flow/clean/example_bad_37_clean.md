```elixir
defmodule AvailabilityCalendar do
  @moduledoc """
  Computes available appointment slots for providers over a requested date range.
  Respects provider working hours, existing bookings, and calendar blocks.
  """

  defmodule ProviderFullyBookedError do
    defexception [:message, :provider_id, :from, :to]
  end

  defmodule PastDateError do
    defexception [:message, :requested_date]
  end

  defmodule WindowTooLargeError do
    defexception [:message, :requested_days, :max_days]
  end

  defmodule UnknownProviderError do
    defexception [:message, :provider_id]
  end

  @max_window_days 60

  @providers %{
    "prov-A" => %{
      id: "prov-A",
      name: "Dr. Rivera",
      working_hours: {9, 17},
      slot_duration_min: 30,
      days_off: [6, 7]
    },
    "prov-B" => %{
      id: "prov-B",
      name: "Dr. Kim",
      working_hours: {8, 12},
      slot_duration_min: 60,
      days_off: [6, 7]
    }
  }

  def slots(provider_id, from_date, to_date) do
    provider = Map.get(@providers, provider_id)

    if is_nil(provider) do
      raise UnknownProviderError,
        message: "Provider '#{provider_id}' is not registered in the system",
        provider_id: provider_id
    end

    today = Date.utc_today()

    if Date.compare(from_date, today) == :lt do
      raise PastDateError,
        message: "from_date #{from_date} is in the past; availability cannot be queried for past dates",
        requested_date: from_date
    end

    requested_days = Date.diff(to_date, from_date)

    if requested_days > @max_window_days do
      raise WindowTooLargeError,
        message:
          "Requested window of #{requested_days} days exceeds the maximum of #{@max_window_days} days",
        requested_days: requested_days,
        max_days: @max_window_days
    end

    {start_hour, end_hour} = provider.working_hours

    available_slots =
      Date.range(from_date, to_date)
      |> Enum.flat_map(fn date ->
        day_of_week = Date.day_of_week(date)

        if day_of_week in provider.days_off do
          []
        else
          generate_slots(date, start_hour, end_hour, provider.slot_duration_min)
        end
      end)
      |> Enum.reject(&booked?(&1, provider_id))

    if available_slots == [] do
      raise ProviderFullyBookedError,
        message:
          "Provider #{provider_id} has no available slots from #{from_date} to #{to_date}",
        provider_id: provider_id,
        from: from_date,
        to: to_date
    end

    %{
      provider_id: provider_id,
      provider_name: provider.name,
      from: from_date,
      to: to_date,
      slot_duration_min: provider.slot_duration_min,
      available_slots: available_slots
    }
  end

  defp generate_slots(date, start_hour, end_hour, duration_min) do
    total_minutes = (end_hour - start_hour) * 60
    slot_count = div(total_minutes, duration_min)

    Enum.map(0..(slot_count - 1), fn i ->
      offset_min = start_hour * 60 + i * duration_min
      time = Time.new!(div(offset_min, 60), rem(offset_min, 60), 0)
      DateTime.new!(date, time, "Etc/UTC")
    end)
  end

  defp booked?(_slot, _provider_id), do: false
end

defmodule BookingSearch do
  @moduledoc """
  Finds the next available appointment slot for a given provider and patient.
  """

  require Logger

  def find_next_available(provider_id, preferred_from) do
    to_date = Date.add(preferred_from, 14)
    Logger.debug("Searching slots for #{provider_id} from #{preferred_from} to #{to_date}")

    # start date, or an overlarge search window are all normal search outcomes
    # — not program errors. The search module must use try...rescue to handle
    # them because AvailabilityCalendar.slots/3 raises instead of returning
    # tagged tuples.
    try do
      result = AvailabilityCalendar.slots(provider_id, preferred_from, to_date)
      next_slot = List.first(result.available_slots)

      Logger.info("Next available slot for #{provider_id}: #{next_slot}")
      {:ok, next_slot, result.provider_name}
    rescue
      e in AvailabilityCalendar.ProviderFullyBookedError ->
        Logger.info("Provider #{e.provider_id} fully booked from #{e.from} to #{e.to}")
        {:error, :no_availability}

      e in AvailabilityCalendar.PastDateError ->
        Logger.warning("Past date requested in availability search: #{e.requested_date}")
        {:error, :past_date}

      e in AvailabilityCalendar.WindowTooLargeError ->
        Logger.warning("Search window too large: #{e.requested_days} days")
        {:error, {:window_too_large, e.max_days}}

      e in AvailabilityCalendar.UnknownProviderError ->
        Logger.error("Unknown provider in availability search: #{e.provider_id}")
        {:error, :unknown_provider}
    end
  end
end
```
