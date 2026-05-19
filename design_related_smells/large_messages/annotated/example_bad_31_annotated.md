# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Healthcare.RecordsTransfer.forward_patient_cohort/2` |
| **Affected function(s)** | `forward_patient_cohort/2` |
| **Short explanation** | The transfer module fetches the complete medical records for an entire patient cohort—including full clinical notes, lab results, medication histories, and diagnostic codes—and sends all records in a single process message to an analytics worker. Each record is a deeply nested structure, and sending thousands of them at once creates a very large message. |

```elixir
defmodule Healthcare.Diagnosis do
  defstruct [:icd10_code, :description, :diagnosed_at, :diagnosing_physician, :status]

  @type t :: %__MODULE__{
          icd10_code: String.t(),
          description: String.t(),
          diagnosed_at: Date.t(),
          diagnosing_physician: String.t(),
          status: :active | :resolved | :chronic
        }
end

defmodule Healthcare.LabResult do
  defstruct [:test_code, :test_name, :value, :unit, :reference_range, :abnormal, :collected_at]

  @type t :: %__MODULE__{
          test_code: String.t(),
          test_name: String.t(),
          value: float(),
          unit: String.t(),
          reference_range: {float(), float()},
          abnormal: boolean(),
          collected_at: DateTime.t()
        }
end

defmodule Healthcare.Medication do
  defstruct [:ndc_code, :name, :dosage, :frequency, :route, :prescribed_at, :discontinued_at]

  @type t :: %__MODULE__{
          ndc_code: String.t(),
          name: String.t(),
          dosage: String.t(),
          frequency: String.t(),
          route: String.t(),
          prescribed_at: Date.t(),
          discontinued_at: Date.t() | nil
        }
end

defmodule Healthcare.ClinicalNote do
  defstruct [:note_id, :author, :note_type, :content, :created_at, :signed_at]

  @type t :: %__MODULE__{
          note_id: String.t(),
          author: String.t(),
          note_type: String.t(),
          content: String.t(),
          created_at: DateTime.t(),
          signed_at: DateTime.t() | nil
        }
end

defmodule Healthcare.PatientRecord do
  @enforce_keys [:patient_id, :mrn, :diagnoses, :lab_results, :medications, :notes]
  defstruct [
    :patient_id,
    :mrn,
    :date_of_birth,
    :sex,
    :blood_type,
    :diagnoses,
    :lab_results,
    :medications,
    :notes,
    :allergies,
    :vitals_history
  ]

  @type t :: %__MODULE__{
          patient_id: String.t(),
          mrn: String.t(),
          date_of_birth: Date.t(),
          sex: String.t(),
          blood_type: String.t(),
          diagnoses: [Healthcare.Diagnosis.t()],
          lab_results: [Healthcare.LabResult.t()],
          medications: [Healthcare.Medication.t()],
          notes: [Healthcare.ClinicalNote.t()],
          allergies: [map()],
          vitals_history: [map()]
        }
end

defmodule Healthcare.RecordRepository do
  @moduledoc "Simulates a clinical records database fetch."

  @spec fetch_cohort(String.t()) :: [Healthcare.PatientRecord.t()]
  def fetch_cohort(study_id) do
    now = DateTime.utc_now()
    today = Date.utc_today()
    _study_id = study_id

    Enum.map(1..8_000, fn n ->
      %Healthcare.PatientRecord{
        patient_id: "PAT-#{n}",
        mrn: String.pad_leading("#{n}", 10, "0"),
        date_of_birth: Date.add(today, -(:rand.uniform(30_000) + 6_570)),
        sex: Enum.random(["M", "F", "O"]),
        blood_type: Enum.random(["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"]),
        allergies:
          Enum.map(1..3, fn a ->
            %{substance: "Allergen #{a}", severity: Enum.random(["mild", "moderate", "severe"]),
              reaction: "Reaction type #{a}"}
          end),
        vitals_history:
          Enum.map(1..24, fn v ->
            %{timestamp: DateTime.add(now, -v * 3600, :second),
              bp_systolic: 110 + :rand.uniform(50),
              bp_diastolic: 70 + :rand.uniform(30),
              heart_rate: 55 + :rand.uniform(60),
              temperature_c: 36.0 + :rand.uniform() * 2,
              spo2: 94 + :rand.uniform(6)}
          end),
        diagnoses:
          Enum.map(1..8, fn d ->
            %Healthcare.Diagnosis{
              icd10_code: "#{<<65 + rem(d, 26)::utf8>>}#{rem(n * d, 99) + 10}.#{rem(d, 9)}",
              description: "Diagnosis #{d} description for patient #{n}",
              diagnosed_at: Date.add(today, -:rand.uniform(1000)),
              diagnosing_physician: "DR-#{rem(n * d, 500) + 1}",
              status: Enum.random([:active, :resolved, :chronic])
            }
          end),
        lab_results:
          Enum.map(1..30, fn l ->
            val = :rand.uniform() * 200
            %Healthcare.LabResult{
              test_code: "LAB#{rem(l, 100) + 1}",
              test_name: "Lab Test #{l}",
              value: Float.round(val, 2),
              unit: Enum.random(["mg/dL", "mmol/L", "U/L", "g/dL", "%"]),
              reference_range: {20.0, 180.0},
              abnormal: val < 20.0 or val > 180.0,
              collected_at: DateTime.add(now, -:rand.uniform(365) * 86_400, :second)
            }
          end),
        medications:
          Enum.map(1..10, fn m ->
            %Healthcare.Medication{
              ndc_code: "#{rem(n * m, 99_999) + 10000}-#{rem(m, 999) + 100}-#{rem(m, 9) + 10}",
              name: "Medication #{rem(n * m, 200) + 1}",
              dosage: "#{:rand.uniform(500)} mg",
              frequency: Enum.random(["once daily", "twice daily", "every 8h", "as needed"]),
              route: Enum.random(["oral", "IV", "topical", "inhaled"]),
              prescribed_at: Date.add(today, -:rand.uniform(500)),
              discontinued_at: if(rem(m, 3) == 0, do: Date.add(today, -:rand.uniform(100)))
            }
          end),
        notes:
          Enum.map(1..12, fn note ->
            %Healthcare.ClinicalNote{
              note_id: "NOTE-#{n}-#{note}",
              author: "DR-#{rem(n * note, 500) + 1}",
              note_type: Enum.random(["progress", "discharge", "consult", "admission"]),
              content:
                "Clinical note #{note} for patient #{n}. " <>
                  String.duplicate("Patient presents with no acute distress. Vitals stable. ", 10),
              created_at: DateTime.add(now, -note * 86_400, :second),
              signed_at: DateTime.add(now, -(note * 86_400 - 3600), :second)
            }
          end)
      }
    end)
  end
end

defmodule Healthcare.CohortAnalyticsWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:analyse_cohort, study_id, records}, _state) do
    {:noreply, {study_id, length(records)}}
  end
end

defmodule Healthcare.RecordsTransfer do
  @moduledoc """
  Retrieves complete patient records for a research cohort and forwards
  them to the analytics worker for statistical analysis.
  """

  require Logger

  @spec forward_patient_cohort(pid(), String.t()) :: :ok
  def forward_patient_cohort(analytics_pid, study_id) do
    Logger.info("Fetching records for study cohort #{study_id}...")

    records = Healthcare.RecordRepository.fetch_cohort(study_id)

    Logger.info(
      "Fetched #{length(records)} patient records. Forwarding to analytics worker..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `records` is a list of 8,000
    # PatientRecord structs, each with 8 diagnoses, 30 lab results, 10
    # medications, 12 clinical notes (with long text content), 24 vitals
    # entries, and allergy records. Sending this deeply nested list in one
    # process message triggers a full heap-to-heap deep copy that can run
    # for seconds, blocking RecordsTransfer and starving other work.
    send(analytics_pid, {:analyse_cohort, study_id, records})
    # VALIDATION: SMELL END

    Logger.info("Patient cohort forwarded for study #{study_id}.")
    :ok
  end
end
```
