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

  def get_max_wait_minutes(:emergency), do: 0
  def get_max_wait_minutes(:urgent),    do: 30
  def get_max_wait_minutes(:routine),   do: 120
  def get_max_wait_minutes(_),          do: 60

  def assign_department(:emergency), do: :resus_bay
  def assign_department(:urgent),    do: :acute_care
  def assign_department(:routine),   do: :minor_injuries
  def assign_department(_),          do: :waiting_room

  def get_escalation_threshold_minutes(:emergency), do: 5
  def get_escalation_threshold_minutes(:urgent),    do: 20
  def get_escalation_threshold_minutes(:routine),   do: 90
  def get_escalation_threshold_minutes(_),          do: 45

  def prepare_intake_protocol(:emergency), do: :trauma_protocol_a
  def prepare_intake_protocol(:urgent),    do: :acute_assessment_b
  def prepare_intake_protocol(:routine),   do: :standard_intake_c
  def prepare_intake_protocol(_),          do: :general_intake

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
