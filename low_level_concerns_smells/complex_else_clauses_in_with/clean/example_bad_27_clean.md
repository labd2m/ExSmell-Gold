```elixir
defmodule Healthcare.PrescriptionSubmitter do
  alias Healthcare.{
    Repo,
    Prescriber,
    Patient,
    DrugInteractionChecker,
    FormularyEngine,
    Prescription,
    PharmacyRouter
  }

  require Logger

  @controlled_substances_requires_dea ~w[opioid benzodiazepine stimulant]a

  def submit_prescription(prescriber_id, patient_id, rx_params) do
    medication_class = Map.get(rx_params, :medication_class)

    with {:ok, prescriber} <- fetch_licensed_prescriber(prescriber_id, medication_class),
         {:ok, patient} <- fetch_active_patient(patient_id),
         :ok <- DrugInteractionChecker.verify(patient, rx_params),
         {:ok, formulary_result} <- FormularyEngine.evaluate(patient, rx_params),
         {:ok, prescription} <- create_prescription(prescriber, patient, rx_params, formulary_result) do
      PharmacyRouter.route(prescription, patient.preferred_pharmacy_id)

      Logger.info(
        "Prescription #{prescription.id} submitted: " <>
          "prescriber=#{prescriber_id} patient=#{patient_id} " <>
          "medication=#{rx_params[:medication_code]}"
      )

      {:ok, prescription}
    else
      {:error, :prescriber_not_found} ->
        Logger.warning("Prescriber #{prescriber_id} not found")
        {:error, :prescriber_not_found}

      {:error, :license_inactive} ->
        Logger.warning("Prescriber #{prescriber_id} has an inactive license")
        {:error, :prescriber_not_authorized}

      {:error, :dea_required} ->
        Logger.warning(
          "Prescriber #{prescriber_id} lacks DEA registration for #{medication_class}"
        )
        {:error, :prescriber_not_authorized}

      {:error, :patient_not_found} ->
        Logger.warning("Patient #{patient_id} not found")
        {:error, :patient_not_found}

      {:error, :patient_inactive} ->
        Logger.warning("Patient #{patient_id} record is inactive")
        {:error, :patient_not_eligible}

      {:error, {:interaction_warning, warnings}} ->
        Logger.warning("Drug interaction warnings for patient #{patient_id}: #{inspect(warnings)}")
        {:error, {:interaction_warning, warnings}}

      {:error, :interaction_contraindicated} ->
        Logger.warning("Contraindicated drug interaction for patient #{patient_id}")
        {:error, :prescription_blocked_interaction}

      {:error, :not_on_formulary} ->
        Logger.info("Medication not on formulary for patient #{patient_id}'s plan")
        {:error, :formulary_rejection}

      {:error, :prior_auth_required} ->
        Logger.info("Prior authorization required for patient #{patient_id}'s medication")
        {:error, :prior_auth_required}

      {:error, :prescription_db_error} ->
        Logger.error("Prescription record could not be saved for patient #{patient_id}")
        {:error, :persistence_failed}
    end
  end

  defp fetch_licensed_prescriber(prescriber_id, medication_class) do
    case Repo.get(Prescriber, prescriber_id) do
      nil ->
        {:error, :prescriber_not_found}

      %Prescriber{license_active: false} ->
        {:error, :license_inactive}

      %Prescriber{dea_registered: false} = p
      when medication_class in @controlled_substances_requires_dea ->
        {:error, :dea_required}

      prescriber ->
        {:ok, prescriber}
    end
  end

  defp fetch_active_patient(patient_id) do
    case Repo.get(Patient, patient_id) do
      nil -> {:error, :patient_not_found}
      %Patient{active: false} -> {:error, :patient_inactive}
      patient -> {:ok, patient}
    end
  end

  defp create_prescription(prescriber, patient, rx_params, formulary_result) do
    %Prescription{}
    |> Prescription.changeset(%{
      prescriber_id: prescriber.id,
      patient_id: patient.id,
      medication_code: rx_params[:medication_code],
      dosage: rx_params[:dosage],
      quantity: rx_params[:quantity],
      refills: rx_params[:refills] || 0,
      instructions: rx_params[:instructions],
      formulary_tier: formulary_result.tier,
      copay_cents: formulary_result.copay_cents,
      status: :pending
    })
    |> Repo.insert()
    |> case do
      {:ok, p} -> {:ok, p}
      {:error, _} -> {:error, :prescription_db_error}
    end
  end
end
```
