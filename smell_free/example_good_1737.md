```elixir
defmodule Workforce.ShiftScheduler do
  @moduledoc """
  Builds weekly shift schedules for a team given a set of availability
  windows and required coverage slots.

  Scheduling is a pure computation: no database calls or side effects
  are performed here. The caller supplies availability and coverage
  requirements; this module returns an assignment plan or a structured
  explanation of why coverage could not be met.
  """

  alias Workforce.AvailabilityWindow
  alias Workforce.CoverageSlot
  alias Workforce.ShiftAssignment
  alias Workforce.SchedulePlan

  @type employee_id :: String.t()
  @type slot_id :: String.t()

  @type availability_map :: %{employee_id() => [AvailabilityWindow.t()]}

  @type schedule_result ::
          {:ok, SchedulePlan.t()}
          | {:error, :no_employees}
          | {:error, :uncoverable_slots, [CoverageSlot.t()]}

  @doc """
  Assigns employees to coverage slots based on declared availability.

  Each slot is assigned the first available employee who covers the
  slot's time range and has not exceeded their weekly hour limit.
  Returns `{:ok, plan}` when all slots are covered, or
  `{:error, :uncoverable_slots, slots}` listing the gaps.
  """
  @spec build(availability_map(), [CoverageSlot.t()], non_neg_integer()) :: schedule_result()
  def build(availability_map, slots, max_hours_per_week)
      when is_map(availability_map) and is_list(slots) and
             is_integer(max_hours_per_week) and max_hours_per_week > 0 do
    case map_size(availability_map) do
      0 ->
        {:error, :no_employees}

      _ ->
        initial_hours = Map.new(availability_map, fn {id, _} -> {id, 0} end)
        assign_slots(slots, availability_map, initial_hours, max_hours_per_week, [])
    end
  end

  @spec assign_slots(
          [CoverageSlot.t()],
          availability_map(),
          %{employee_id() => non_neg_integer()},
          non_neg_integer(),
          [ShiftAssignment.t()]
        ) :: schedule_result()
  defp assign_slots([], _availability, _hours, _max, assignments) do
    plan = %SchedulePlan{assignments: Enum.reverse(assignments), generated_at: DateTime.utc_now()}
    {:ok, plan}
  end

  defp assign_slots([slot | rest], availability, hours, max, assignments) do
    case find_employee(slot, availability, hours, max) do
      {:ok, employee_id} ->
        slot_hours = duration_hours(slot)
        updated_hours = Map.update!(hours, employee_id, &(&1 + slot_hours))

        assignment = %ShiftAssignment{
          slot_id: slot.id,
          employee_id: employee_id,
          start: slot.start,
          finish: slot.finish
        }

        assign_slots(rest, availability, updated_hours, max, [assignment | assignments])

      :no_candidate ->
        collect_uncoverable(rest, availability, hours, max, [slot])
    end
  end

  @spec collect_uncoverable(
          [CoverageSlot.t()],
          availability_map(),
          %{employee_id() => non_neg_integer()},
          non_neg_integer(),
          [CoverageSlot.t()]
        ) :: schedule_result()
  defp collect_uncoverable([], _availability, _hours, _max, uncoverable) do
    {:error, :uncoverable_slots, Enum.reverse(uncoverable)}
  end

  defp collect_uncoverable([slot | rest], availability, hours, max, uncoverable) do
    case find_employee(slot, availability, hours, max) do
      {:ok, _} -> collect_uncoverable(rest, availability, hours, max, uncoverable)
      :no_candidate -> collect_uncoverable(rest, availability, hours, max, [slot | uncoverable])
    end
  end

  @spec find_employee(
          CoverageSlot.t(),
          availability_map(),
          %{employee_id() => non_neg_integer()},
          non_neg_integer()
        ) :: {:ok, employee_id()} | :no_candidate
  defp find_employee(slot, availability, hours, max_hours) do
    candidate =
      availability
      |> Enum.find(fn {employee_id, windows} ->
        scheduled = Map.get(hours, employee_id, 0)
        scheduled + duration_hours(slot) <= max_hours and covers_slot?(windows, slot)
      end)

    case candidate do
      {employee_id, _windows} -> {:ok, employee_id}
      nil -> :no_candidate
    end
  end

  @spec covers_slot?([AvailabilityWindow.t()], CoverageSlot.t()) :: boolean()
  defp covers_slot?(windows, slot) do
    Enum.any?(windows, fn window ->
      DateTime.compare(window.start, slot.start) != :gt and
        DateTime.compare(window.finish, slot.finish) != :lt
    end)
  end

  @spec duration_hours(CoverageSlot.t() | AvailabilityWindow.t()) :: float()
  defp duration_hours(%{start: start, finish: finish}) do
    DateTime.diff(finish, start, :second) / 3600.0
  end
end
```
