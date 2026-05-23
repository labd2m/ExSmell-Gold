# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Healthcare.Records.create_patient/12` |
| **Affected function(s)** | `create_patient/12` |
| **Short explanation** | Twelve parameters encode patient demographic data, contact information, and emergency contact details. Splitting them into `%Demographics{}`, `%ContactInfo{}`, and `%EmergencyContact{}` structs would mirror the domain model, reduce the parameter count to three, and make patient-record creation far more readable and maintainable. |

```elixir
defmodule Healthcare.Records do
  @moduledoc """
  Manages patient registration and medical record creation
  for the clinic management system.
  """

  require Logger

  @valid_blood_types ~w(A+ A- B+ B- AB+ AB- O+ O-)
  @valid_genders ~w(male female other prefer_not_to_say)

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 parameters cover at least three
  # conceptual entities (the patient, their contact details, and their
  # emergency contact). In a medical context the risk of transposing
  # `patient_phone` with `emergency_contact_phone`, or `date_of_birth`
  # with `registration_date`, is non-trivial. Structs would prevent these
  # class of mistakes entirely.
  def create_patient(
        full_name,
        date_of_birth,
        gender,
        blood_type,
        patient_email,
        patient_phone,
        address,
        national_id,
        health_plan_number,
        emergency_contact_name,
        emergency_contact_phone,
        emergency_contact_relationship
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_name(full_name),
         :ok <- validate_dob(date_of_birth),
         :ok <- validate_gender(gender),
         :ok <- validate_blood_type(blood_type),
         :ok <- validate_contact(patient_email, patient_phone),
         :ok <- validate_national_id(national_id) do
      patient = %{
        id: generate_patient_id(),
        full_name: String.trim(full_name),
        date_of_birth: date_of_birth,
        age: compute_age(date_of_birth),
        gender: gender,
        blood_type: blood_type,
        contact: %{
          email: patient_email,
          phone: patient_phone,
          address: address
        },
        identification: %{
          national_id: national_id,
          health_plan_number: health_plan_number
        },
        emergency_contact: %{
          name: emergency_contact_name,
          phone: emergency_contact_phone,
          relationship: emergency_contact_relationship
        },
        medical_history: [],
        allergies: [],
        status: :active,
        registered_at: DateTime.utc_now()
      }

      case persist_patient(patient) do
        {:ok, saved} ->
          Logger.info("Patient registered: #{saved.id} (#{full_name})")
          send_welcome_notification(saved)
          {:ok, saved}

        {:error, :duplicate_national_id} ->
          {:error, :patient_already_registered}

        {:error, reason} ->
          Logger.error("Patient registration failed: #{inspect(reason)}")
          {:error, :registration_failed}
      end
    end
  end

  defp validate_name(n) when byte_size(n) > 1, do: :ok
  defp validate_name(_), do: {:error, "full_name is required"}

  defp validate_dob(%Date{} = dob) do
    if Date.compare(dob, Date.utc_today()) == :lt, do: :ok, else: {:error, "date_of_birth must be in the past"}
  end
  defp validate_dob(_), do: {:error, "date_of_birth must be a Date"}

  defp validate_gender(g) when g in @valid_genders, do: :ok
  defp validate_gender(g), do: {:error, "unsupported gender value: #{g}"}

  defp validate_blood_type(nil), do: :ok
  defp validate_blood_type(bt) when bt in @valid_blood_types, do: :ok
  defp validate_blood_type(bt), do: {:error, "invalid blood_type: #{bt}"}

  defp validate_contact(email, phone) when byte_size(email) > 0 or byte_size(phone) > 0, do: :ok
  defp validate_contact(_, _), do: {:error, "at least one of patient_email or patient_phone is required"}

  defp validate_national_id(id) when byte_size(id) > 0, do: :ok
  defp validate_national_id(_), do: {:error, "national_id is required"}

  defp compute_age(%Date{} = dob) do
    today = Date.utc_today()
    years = today.year - dob.year
    if {today.month, today.day} < {dob.month, dob.day}, do: years - 1, else: years
  end

  defp persist_patient(patient) do
    {:ok, patient}
  end

  defp send_welcome_notification(patient) do
    Logger.debug("Sending welcome notification to patient #{patient.id}")
    :ok
  end

  defp generate_patient_id do
    "PAT-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end
```
