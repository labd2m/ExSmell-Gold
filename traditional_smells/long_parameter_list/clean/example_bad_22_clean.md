```elixir
defmodule Healthcare.Patients do
  @moduledoc """
  Handles patient registration and medical record creation
  in the electronic health record (EHR) subsystem.
  """

  require Logger

  alias Healthcare.Repo
  alias Healthcare.Schemas.Patient
  alias Healthcare.Schemas.ClinicalRecord
  alias Healthcare.PortalMailer
  alias Healthcare.AuditLogger

  @valid_genders ~w(male female other prefer_not_to_say)
  @valid_blood_types ~w(A+ A- B+ B- AB+ AB- O+ O-)

  def create_patient_record(
        first_name,
        last_name,
        birth_date,
        gender,
        email,
        phone,
        emergency_contact_name,
        emergency_contact_phone,
        blood_type,
        allergies
      ) do
    with :ok <- validate_name(first_name, :first_name),
         :ok <- validate_name(last_name, :last_name),
         :ok <- validate_birth_date(birth_date),
         :ok <- validate_gender(gender),
         :ok <- validate_email(email),
         :ok <- validate_blood_type(blood_type) do
      patient_attrs = %{
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        birth_date: birth_date,
        gender: gender,
        email: String.downcase(String.trim(email)),
        phone: phone,
        emergency_contact_name: emergency_contact_name,
        emergency_contact_phone: emergency_contact_phone,
        status: :active,
        inserted_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        case Repo.insert(Patient.changeset(%Patient{}, patient_attrs)) do
          {:ok, patient} ->
            clinical_attrs = %{
              patient_id: patient.id,
              blood_type: blood_type,
              allergies: normalize_allergies(allergies),
              updated_at: DateTime.utc_now()
            }

            {:ok, _record} =
              Repo.insert(ClinicalRecord.changeset(%ClinicalRecord{}, clinical_attrs))

            AuditLogger.log(:patient_created, %{
              patient_id: patient.id,
              actor: :system
            })

            PortalMailer.send_registration_confirmation(patient)
            Logger.info("Patient record created: #{patient.id}")
            patient

          {:error, changeset} ->
            Logger.error("Patient creation failed: #{inspect(changeset.errors)}")
            Repo.rollback(:creation_failed)
        end
      end)
    end
  end

  defp validate_name(name, field) do
    if is_binary(name) and String.length(String.trim(name)) >= 1 do
      :ok
    else
      {:error, {field, :blank}}
    end
  end

  defp validate_birth_date(date) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        if Date.compare(d, Date.utc_today()) == :lt, do: :ok, else: {:error, :future_birth_date}

      _ ->
        {:error, :invalid_birth_date}
    end
  end

  defp validate_gender(g) when g in @valid_genders, do: :ok
  defp validate_gender(_), do: {:error, :invalid_gender}

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_blood_type(nil), do: :ok
  defp validate_blood_type(bt) when bt in @valid_blood_types, do: :ok
  defp validate_blood_type(_), do: {:error, :invalid_blood_type}

  defp normalize_allergies(nil), do: []
  defp normalize_allergies(list) when is_list(list), do: Enum.map(list, &String.trim/1)
end
```
