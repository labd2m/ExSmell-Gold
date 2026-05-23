# Example Bad 12 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `get_max_wait_minutes/1`, `assign_department/1`, `get_escalation_threshold_minutes/1`, and `prepare_intake_protocol/1` inside `Healthcare.TriageProcessor`
- **Affected Functions**: `get_max_wait_minutes/1`, `assign_department/1`, `get_escalation_threshold_minutes/1`, `prepare_intake_protocol/1`
- **Explanation**: The triage priority logic (`:emergency`, `:urgent`, `:routine`) is scattered across four separate functions. Adding a new level (e.g., `:critical`) forces four independent edits throughout the module, characteristic of Shotgun Surgery.

```elixir
defmodule Healthcare.TriageProcessor do
  @moduledoc """
  Processes patient triage events in the emergency department.
  Handles wait time policies, department routing, escalation thresholds,
  and intake protocol selection based on assigned priority levels.
  """

  alias Healthcare.{
    Patient, TriageRecord, DepartmentRouter,
    EscalationMonitor, IntakeProtocol, NurseStation
  }

  def process_arrival(%Patient{} = patient, symptoms, vitals) do
    priority = assess_priority(vitals, symptoms)

    with {:ok, record} <- create_triage_record(patient, priority, vitals),
         {:ok, dept}   <- route_to_department(record),
         :ok           <- register_escalation_watch(record),
         {:ok, proto}  <- assign_intake_protocol(record) do
      NurseStation.notify_arrival(dept, record, proto)
      {:ok, record}
    end
  end

  defp create_triage_record(patient, priority, vitals) do
    record = %TriageRecord{
      patient_id:     patient.id,
      priority:       priority,
      vitals:         vitals,
      max_wait_mins:  get_max_wait_minutes(priority),
      registered_at:  DateTime.utc_now(),
      status:         :waiting
    }

    TriageRecord.insert(record)
  end

  defp route_to_department(record) do
    dept = assign_department(record.priority)
    DepartmentRouter.route(record, dept)
  end

  defp register_escalation_watch(record) do
    threshold = get_escalation_threshold_minutes(record.priority)
    EscalationMonitor.register(record.id, threshold)
  end

  defp assign_intake_protocol(record) do
    protocol_id = prepare_intake_protocol(record.priority)
    IntakeProtocol.load(protocol_id)
  end

  defp assess_priority(vitals, symptoms) do
    cond do
      vitals.spo2 < 90 or vitals.systolic_bp < 80 -> :emergency
      vitals.heart_rate > 130 or Enum.any?(symptoms, &(&1 in [:chest_pain, :stroke_symptoms])) -> :urgent
      true -> :routine
    end
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new priority level (e.g., :critical)
  # requires a new clause here AND in assign_department/1, get_escalation_threshold_minutes/1,
  # and prepare_intake_protocol/1 — four scattered changes for one new level.
  def get_max_wait_minutes(:emergency), do: 0
  def get_max_wait_minutes(:urgent),    do: 30
  def get_max_wait_minutes(:routine),   do: 120
  def get_max_wait_minutes(_),          do: 60
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new priority level also requires a new
  # department assignment clause here, independent of get_max_wait_minutes/1.
  def assign_department(:emergency), do: :resus_bay
  def assign_department(:urgent),    do: :acute_care
  def assign_department(:routine),   do: :minor_injuries
  def assign_department(_),          do: :waiting_room
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new priority level also requires a new
  # escalation threshold clause here, independent of the previous two locations.
  def get_escalation_threshold_minutes(:emergency), do: 5
  def get_escalation_threshold_minutes(:urgent),    do: 20
  def get_escalation_threshold_minutes(:routine),   do: 90
  def get_escalation_threshold_minutes(_),          do: 45
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new priority level also needs a new protocol
  # clause here, completing the four-location change for every new priority.
  def prepare_intake_protocol(:emergency), do: :trauma_protocol_a
  def prepare_intake_protocol(:urgent),    do: :acute_assessment_b
  def prepare_intake_protocol(:routine),   do: :standard_intake_c
  def prepare_intake_protocol(_),          do: :general_intake
  # VALIDATION: SMELL END [location 4 of 4]

  def escalate_patient(%TriageRecord{priority: :routine} = record) do
    new_record = %{record | priority: :urgent, escalated_at: DateTime.utc_now()}
    with {:ok, updated} <- TriageRecord.update(new_record) do
      EscalationMonitor.reregister(updated.id, get_escalation_threshold_minutes(:urgent))
      NurseStation.notify_escalation(updated)
      {:ok, updated}
    end
  end

  def escalate_patient(%TriageRecord{priority: :urgent} = record) do
    new_record = %{record | priority: :emergency, escalated_at: DateTime.utc_now()}
    with {:ok, updated} <- TriageRecord.update(new_record) do
      EscalationMonitor.reregister(updated.id, get_escalation_threshold_minutes(:emergency))
      DepartmentRouter.route(updated, assign_department(:emergency))
      {:ok, updated}
    end
  end

  def escalate_patient(%TriageRecord{priority: :emergency}) do
    {:error, :already_highest_priority}
  end

  def list_waiting_by_priority do
    [:emergency, :urgent, :routine]
    |> Enum.flat_map(fn p ->
      TriageRecord.list_waiting(priority: p)
    end)
  end
end
```
