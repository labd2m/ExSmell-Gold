# Annotated Example 13 — Large Messages

| Field                  | Value                                                                        |
|------------------------|------------------------------------------------------------------------------|
| **Smell name**         | Large messages                                                               |
| **Expected location**  | `Healthcare.AnalyticsBatch.dispatch/2`                                      |
| **Affected function(s)**| `dispatch/2`, `handle_info/2` (GenServer)                                  |
| **Explanation**        | The batch dispatcher collects a large list of patient records — each containing clinical notes, medication lists, diagnostic codes, and encounter histories — and sends the entire collection to the analytics worker in a single `send/2`. Patient records are among the most data-rich domain objects; a batch of a few thousand records can represent hundreds of megabytes of nested Elixir structures. Copying this between processes blocks the dispatcher and can cause the analytics worker's mailbox to grow beyond manageable size if sends outpace processing. |

```elixir
defmodule Healthcare.DiagnosticCode do
  defstruct [:code, :system, :description, :onset_date, :resolved_date, :severity]
end

defmodule Healthcare.Medication do
  defstruct [
    :name,
    :dose_mg,
    :frequency,
    :route,
    :prescribed_by,
    :prescribed_at,
    :active
  ]
end

defmodule Healthcare.Encounter do
  defstruct [
    :encounter_id,
    :type,
    :provider_id,
    :facility_id,
    :started_at,
    :ended_at,
    :chief_complaint,
    :clinical_notes,
    :diagnoses,
    :procedures
  ]
end

defmodule Healthcare.Patient do
  @enforce_keys [:id, :mrn, :dob, :gender]
  defstruct [
    :id,
    :mrn,
    :dob,
    :gender,
    :name,
    :insurance_ids,
    :allergies,
    :diagnoses,
    :medications,
    :encounters,
    :vitals_history,
    :contact_info
  ]
end

defmodule Healthcare.PatientRepo do
  @moduledoc "Simulates fetching a cohort of patients for analytics processing."

  @spec load_cohort(String.t()) :: list(Healthcare.Patient.t())
  def load_cohort(cohort_id) do
    Enum.map(1..5_000, fn i ->
      %Healthcare.Patient{
        id: "PAT-#{cohort_id}-#{i}",
        mrn: "MRN#{String.pad_leading("#{i}", 8, "0")}",
        dob: Date.utc_today() |> Date.add(-rem(i * 365, 36_500)),
        gender: Enum.random(["M", "F", "O"]),
        name: "Patient #{i}",
        insurance_ids: ["INS-#{rem(i, 500)}", "SEC-#{rem(i, 200)}"],
        allergies: Enum.map(1..rem(i, 5), fn j -> "allergen-#{j}" end),
        diagnoses: Enum.map(1..4, fn j ->
          %Healthcare.DiagnosticCode{
            code: "ICD10-#{j}#{rem(i, 100)}",
            system: "ICD-10-CM",
            description: "Condition #{j} for patient #{i}",
            onset_date: Date.utc_today() |> Date.add(-j * 90),
            resolved_date: if(rem(j, 2) == 0, do: Date.utc_today(), else: nil),
            severity: Enum.random(["mild", "moderate", "severe"])
          }
        end),
        medications: Enum.map(1..6, fn j ->
          %Healthcare.Medication{
            name: "Drug-#{j}",
            dose_mg: j * 10,
            frequency: "twice daily",
            route: "oral",
            prescribed_by: "DOC-#{rem(j, 50)}",
            prescribed_at: DateTime.utc_now(),
            active: rem(j, 3) != 0
          }
        end),
        encounters: Enum.map(1..8, fn j ->
          %Healthcare.Encounter{
            encounter_id: "ENC-#{i}-#{j}",
            type: Enum.random(["outpatient", "inpatient", "emergency"]),
            provider_id: "PROV-#{rem(j, 100)}",
            facility_id: "FAC-#{rem(j, 10)}",
            started_at: DateTime.utc_now() |> DateTime.add(-j * 86_400 * 30),
            ended_at: DateTime.utc_now() |> DateTime.add(-j * 86_400 * 30 + 7_200),
            chief_complaint: "Complaint #{j}",
            clinical_notes: "Patient presented with symptoms #{j}. Examination findings noted.",
            diagnoses: ["ICD10-#{j}#{rem(i, 100)}"],
            procedures: ["PROC-#{j}"]
          }
        end),
        vitals_history: Enum.map(1..12, fn j ->
          %{
            recorded_at: DateTime.utc_now() |> DateTime.add(-j * 86_400 * 30),
            systolic_bp: 110 + rem(j * i, 40),
            diastolic_bp: 70 + rem(j * i, 20),
            heart_rate: 60 + rem(j + i, 40),
            weight_kg: 60.0 + rem(i, 50),
            temp_c: 36.5 + :rand.uniform() * 0.5
          }
        end),
        contact_info: %{
          phone: "+5511#{String.pad_leading("#{i}", 8, "0")}",
          email: "patient#{i}@example.com",
          emergency_contact: "Guardian #{i}"
        }
      }
    end)
  end
end

defmodule Healthcare.AnalyticsWorker do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{processed: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:process_cohort, cohort_id, patients}, state) do
    avg_age =
      patients
      |> Enum.map(fn p -> Date.diff(Date.utc_today(), p.dob) |> div(365) end)
      |> then(fn ages -> if ages == [], do: 0, else: Enum.sum(ages) / length(ages) end)

    _ = {cohort_id, avg_age}
    {:noreply, %{state | processed: state.processed + length(patients)}}
  end
end

defmodule Healthcare.AnalyticsBatch do
  @moduledoc "Loads patient cohorts and dispatches them to analytics workers."

  require Logger

  @spec dispatch(pid(), String.t()) :: :ok
  def dispatch(worker_pid, cohort_id) do
    Logger.info("Loading cohort #{cohort_id} for analytics processing")

    patients = Healthcare.PatientRepo.load_cohort(cohort_id)

    Logger.info("Dispatching #{length(patients)} patients to analytics worker")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `patients` is a list of 5 000
    # Patient structs, each with 4 DiagnosticCode structs, 6 Medication
    # structs, 8 Encounter structs (each with its own clinical_notes binary),
    # 12 vitals maps, and a contact_info map. Sending this richly-nested
    # structure to the analytics worker in one `send/2` triggers a deep
    # heap-to-heap copy of what amounts to a very large graph of Elixir
    # terms. The dispatcher process is blocked for the entire duration of
    # the copy, and with multiple cohorts dispatched in parallel the blocking
    # periods overlap, creating a significant performance bottleneck.
    send(worker_pid, {:process_cohort, cohort_id, patients})
    # VALIDATION: SMELL END

    :ok
  end

  @spec run_all(pid(), list(String.t())) :: :ok
  def run_all(worker_pid, cohort_ids) do
    Enum.each(cohort_ids, &dispatch(worker_pid, &1))
  end
end
```
