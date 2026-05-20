# Annotated Example 39

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `HealthRecordManager.record/1`
- **Affected function(s):** `record/1`
- **Short explanation:** `record/1` handles patient vitals recording, prescription issuance, and lab result ingestion — three unrelated clinical operations — under one multi-clause function. Each involves different clinical workflows, different access controls, and different regulatory obligations (HIPAA, e-prescribing standards, lab HL7 interfaces).

```elixir
defmodule HealthRecordManager do
  @moduledoc """
  Electronic health record management module for the clinical platform.
  Records patient vitals, manages prescription issuance, and ingests
  lab results from connected laboratory systems.
  """

  alias HealthRecordManager.{
    VitalsEntry,
    PrescriptionOrder,
    LabResultEntry,
    PatientStore,
    VitalsStore,
    PrescriptionStore,
    LabResultStore,
    PharmacyNetwork,
    AlertEngine,
    AuditLog,
    ProviderNotifier
  }

  require Logger

  @doc """
  Record a clinical data entry for a patient.

  Accepts a `%VitalsEntry{}`, `%PrescriptionOrder{}`, or `%LabResultEntry{}`
  and stores the corresponding clinical record.

  ## Examples

      iex> HealthRecordManager.record(%VitalsEntry{patient_id: "pt_001", systolic_bp: 120, diastolic_bp: 80})
      {:ok, %{vitals_id: "vit_001", alerts: []}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because recording patient vitals, issuing
  # a prescription, and ingesting lab results are entirely different clinical
  # operations. Each requires different clinical validation (range checks vs
  # drug interaction screening vs reference range evaluation), different
  # regulatory interfaces (e-prescribing network, HL7 FHIR, HIPAA audit),
  # and different alert thresholds. Grouping them under `record/1` conflates
  # unrelated healthcare workflows.

  def record(%VitalsEntry{
        patient_id: patient_id,
        provider_id: provider_id,
        systolic_bp: sbp,
        diastolic_bp: dbp,
        heart_rate: hr,
        temperature: temp,
        oxygen_saturation: spo2,
        recorded_at: recorded_at
      }) do
    with {:ok, patient} <- PatientStore.find(patient_id),
         alerts = evaluate_vitals_alerts(sbp, dbp, hr, temp, spo2),
         {:ok, vitals} <-
           VitalsStore.create(%{
             patient_id: patient_id,
             provider_id: provider_id,
             systolic_bp: sbp,
             diastolic_bp: dbp,
             heart_rate: hr,
             temperature: temp,
             oxygen_saturation: spo2,
             alerts: Enum.map(alerts, & &1.code),
             recorded_at: recorded_at
           }),
         :ok <- AuditLog.append(:vitals_recorded, %{patient_id: patient_id, provider_id: provider_id, vitals_id: vitals.id}),
         :ok <- maybe_escalate_vitals(alerts, patient, provider_id) do
      Logger.info("Vitals recorded for patient #{patient_id}: #{length(alerts)} alert(s)")
      {:ok, %{vitals_id: vitals.id, alerts: Enum.map(alerts, & &1.message)}}
    end
  end

  # record prescription order issued by an authorised prescriber
  def record(%PrescriptionOrder{
        patient_id: patient_id,
        prescriber_id: prescriber_id,
        medication: medication,
        dosage: dosage,
        frequency: frequency,
        duration_days: duration,
        pharmacy_id: pharmacy_id,
        notes: notes
      }) do
    with {:ok, patient} <- PatientStore.find(patient_id),
         {:ok, prescriber} <- PatientStore.find_provider(prescriber_id),
         :ok <- validate_prescribing_authority(prescriber, medication),
         {:ok, interactions} <- check_drug_interactions(patient_id, medication),
         :ok <- validate_no_contraindications(interactions),
         {:ok, prescription} <-
           PrescriptionStore.create(%{
             patient_id: patient_id,
             prescriber_id: prescriber_id,
             medication: medication,
             dosage: dosage,
             frequency: frequency,
             duration_days: duration,
             pharmacy_id: pharmacy_id,
             notes: notes,
             status: :active,
             issued_at: DateTime.utc_now()
           }),
         {:ok, _} <- PharmacyNetwork.transmit(pharmacy_id, prescription),
         :ok <- AuditLog.append(:prescription_issued, %{patient_id: patient_id, prescriber_id: prescriber_id, rx_id: prescription.id}) do
      Logger.info("Prescription #{prescription.id} issued for patient #{patient_id} by prescriber #{prescriber_id}")
      {:ok, prescription}
    end
  end

  # record lab result ingested from external laboratory system
  def record(%LabResultEntry{
        patient_id: patient_id,
        lab_id: lab_id,
        test_code: test_code,
        value: value,
        unit: unit,
        collected_at: collected_at,
        resulted_at: resulted_at
      }) do
    with {:ok, reference_range} <- LabResultStore.get_reference_range(test_code),
         status = classify_lab_result(value, reference_range),
         {:ok, result} <-
           LabResultStore.create(%{
             patient_id: patient_id,
             lab_id: lab_id,
             test_code: test_code,
             value: value,
             unit: unit,
             reference_range: reference_range,
             status: status,
             collected_at: collected_at,
             resulted_at: resulted_at,
             ingested_at: DateTime.utc_now()
           }),
         :ok <- AuditLog.append(:lab_result_ingested, %{patient_id: patient_id, lab_id: lab_id, result_id: result.id}),
         :ok <- maybe_alert_abnormal(status, patient_id, test_code, value) do
      Logger.info("Lab result ingested for patient #{patient_id}: #{test_code}=#{value} #{unit} (#{status})")
      {:ok, %{result_id: result.id, status: status}}
    end
  end

  # VALIDATION: SMELL END

  defp evaluate_vitals_alerts(sbp, dbp, hr, temp, spo2) do
    [
      if(sbp > 180 or sbp < 90, do: %{code: :bp_critical, message: "Critical BP: #{sbp}/#{dbp}"}, else: nil),
      if(hr > 120 or hr < 40, do: %{code: :hr_critical, message: "Critical HR: #{hr} bpm"}, else: nil),
      if(temp > 39.5, do: %{code: :hyperthermia, message: "High temperature: #{temp}°C"}, else: nil),
      if(spo2 < 90, do: %{code: :hypoxia, message: "Low O2 saturation: #{spo2}%"}, else: nil)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_escalate_vitals([], _patient, _provider_id), do: :ok

  defp maybe_escalate_vitals(alerts, patient, provider_id) do
    ProviderNotifier.send_vitals_alert(provider_id, patient.id, alerts)
  end

  defp validate_prescribing_authority(prescriber, medication) do
    if medication.schedule in prescriber.authorized_schedules do
      :ok
    else
      {:error, :not_authorized_to_prescribe_schedule}
    end
  end

  defp check_drug_interactions(patient_id, medication) do
    {:ok, active_medications} = PrescriptionStore.list_active(patient_id)
    interactions = Enum.filter(active_medications, &conflicts_with?(&1, medication))
    {:ok, interactions}
  end

  defp conflicts_with?(existing, new_med) do
    new_med.contraindicated_with |> Enum.member?(existing.medication.code)
  end

  defp validate_no_contraindications([]), do: :ok
  defp validate_no_contraindications(interactions), do: {:error, {:drug_interactions, interactions}}

  defp classify_lab_result(value, %{low: low, high: high}) do
    cond do
      value < low -> :low
      value > high -> :high
      true -> :normal
    end
  end

  defp maybe_alert_abnormal(:normal, _patient_id, _test_code, _value), do: :ok

  defp maybe_alert_abnormal(status, patient_id, test_code, value) do
    AlertEngine.notify_abnormal_lab(patient_id, test_code, value, status)
  end
end
```
