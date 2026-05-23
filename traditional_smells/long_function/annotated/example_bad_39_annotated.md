# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Healthcare.PatientIntakeService.register_patient/2`
- **Affected function(s):** `register_patient/2`
- **Short explanation:** `register_patient/2` combines duplicate-patient detection, demographic validation, insurance eligibility verification, allergy record seeding, primary-care physician assignment, EMR-system sync, consent-form creation, and intake-summary email into one over-long sequential function body.

---

```elixir
defmodule Healthcare.PatientIntakeService do
  @moduledoc """
  Registers new patients, verifies insurance eligibility,
  seeds clinical records, and synchronises with the EMR system.
  """

  require Logger

  alias Healthcare.{
    Patient, Insurance, Allergy, Physician,
    ConsentForm, EMRBridge, Mailer
  }

  @min_age_years   0
  @max_age_years   130
  @default_consent_forms ["general_treatment", "privacy_notice", "data_sharing"]

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `register_patient/2` sequentially
  # handles duplicate detection, demographic field validation, insurance
  # eligibility checking, allergy record initialisation, PCP assignment,
  # EMR synchronisation, consent-form generation, and confirmation-email
  # dispatch, all inside a single function body exceeding 110 lines with
  # no responsibility extracted to private helper functions.
  def register_patient(intake_params, opts \\ []) do
    registered_by = Keyword.get(opts, :registered_by, "reception")

    first_name = String.trim(intake_params["first_name"] || "")
    last_name  = String.trim(intake_params["last_name"]  || "")
    dob_string = intake_params["date_of_birth"]
    email      = String.trim(intake_params["email"]      || "")
    phone      = intake_params["phone"]
    gender     = intake_params["gender"]
    address    = intake_params["address"]

    # 1. Field presence validation
    cond do
      first_name == "" or last_name == "" ->
        {:error, %{name: "first and last name required"}}

      is_nil(dob_string) ->
        {:error, %{date_of_birth: "required"}}

      email == "" ->
        {:error, %{email: "required"}}

      true ->
        with {:ok, dob} <- Date.from_iso8601(dob_string) do
          age = Date.diff(Date.utc_today(), dob) |> div(365)

          cond do
            age < @min_age_years or age > @max_age_years ->
              {:error, %{date_of_birth: "invalid age: #{age}"}}

            gender not in ["male", "female", "non_binary", "prefer_not_to_say"] ->
              {:error, %{gender: "invalid value"}}

            true ->
              # 2. Check for duplicate patient record
              possible_duplicate =
                Patient.find_duplicate(%{
                  first_name: first_name,
                  last_name:  last_name,
                  dob:        dob
                })

              if possible_duplicate do
                Logger.warning("Possible duplicate patient detected — existing ID #{possible_duplicate.id}")
                {:error, {:possible_duplicate, possible_duplicate.id}}
              else
                # 3. Verify insurance eligibility
                insurance_status =
                  if insurance_info = intake_params["insurance"] do
                    case Insurance.verify_eligibility(%{
                      provider_id:  insurance_info["provider_id"],
                      member_id:    insurance_info["member_id"],
                      group_number: insurance_info["group_number"],
                      dob:          dob
                    }) do
                      {:ok, %{eligible: true} = elig} ->
                        Logger.info("Insurance eligible: #{insurance_info["provider_id"]}")
                        {:verified, elig}

                      {:ok, %{eligible: false}} ->
                        Logger.warning("Insurance not eligible for new patient")
                        {:ineligible, nil}

                      {:error, reason} ->
                        Logger.warning("Insurance check failed: #{inspect(reason)}")
                        {:error, nil}
                    end
                  else
                    {:uninsured, nil}
                  end

                # 4. Persist patient record
                patient_attrs = %{
                  first_name:       first_name,
                  last_name:        last_name,
                  date_of_birth:    dob,
                  email:            email,
                  phone:            phone,
                  gender:           gender,
                  address:          address,
                  insurance_status: elem(insurance_status, 0),
                  registered_by:    registered_by,
                  inserted_at:      DateTime.utc_now()
                }

                case Patient.insert(patient_attrs) do
                  {:error, reason} ->
                    Logger.error("Patient insert failed: #{inspect(reason)}")
                    {:error, :persistence_failed}

                  {:ok, patient} ->
                    Logger.info("New patient #{patient.id} registered")

                    # 5. Seed allergy records
                    reported_allergies = intake_params["allergies"] || []

                    Enum.each(reported_allergies, fn allergy ->
                      Allergy.insert(%{
                        patient_id: patient.id,
                        substance:  allergy["substance"],
                        reaction:   allergy["reaction"],
                        severity:   allergy["severity"] || "unknown",
                        reported_at: DateTime.utc_now()
                      })
                    end)

                    # 6. Assign a primary-care physician
                    physician =
                      case intake_params["preferred_physician_id"] do
                        nil ->
                          Physician.find_available(accepting_new_patients: true)

                        pref_id ->
                          Physician.get(pref_id) || Physician.find_available(accepting_new_patients: true)
                      end

                    if physician do
                      Patient.assign_physician(patient.id, physician.id)
                    end

                    # 7. Sync to EMR
                    Task.start(fn ->
                      case EMRBridge.create_patient(patient) do
                        {:ok, emr_id} ->
                          Patient.set_emr_id(patient.id, emr_id)
                          Logger.info("EMR record created: #{emr_id} for patient #{patient.id}")

                        {:error, reason} ->
                          Logger.error("EMR sync failed for #{patient.id}: #{inspect(reason)}")
                      end
                    end)

                    # 8. Generate consent forms
                    Enum.each(@default_consent_forms, fn form_type ->
                      ConsentForm.create(%{
                        patient_id:  patient.id,
                        form_type:   form_type,
                        status:      :pending,
                        expires_at:  Date.add(Date.utc_today(), 365),
                        created_at:  DateTime.utc_now()
                      })
                    end)

                    # 9. Send registration confirmation
                    physician_name =
                      if physician, do: "#{physician.first_name} #{physician.last_name}", else: "TBD"

                    email_body = """
                    Dear #{first_name},

                    Thank you for registering with our clinic.

                    Patient ID  : #{patient.id}
                    Your PCP    : Dr. #{physician_name}
                    Next step   : Please complete the consent forms in your patient portal.

                    If you have any questions, call us at (555) 000-1234.
                    """

                    case Mailer.send_email(email, "Registration Confirmed", email_body) do
                      {:ok, _}         -> :ok
                      {:error, reason} -> Logger.warning("Confirmation email failed: #{inspect(reason)}")
                    end

                    {:ok, patient}
                end
              end
          end
        else
          _ -> {:error, %{date_of_birth: "invalid date format"}}
        end
    end
  end
  # VALIDATION: SMELL END
end
```
