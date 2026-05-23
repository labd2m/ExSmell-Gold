# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Healthcare.EligibilityChecker.check_screening_eligibility/2` and `Healthcare.EligibilityChecker.check_trial_eligibility/2` |
| **Affected functions** | `check_screening_eligibility/2`, `check_trial_eligibility/2` |
| **Short explanation** | Both functions duplicate the age-and-coverage resolution block (computing the patient's age from DOB, checking active coverage, resolving the effective coverage tier). Any change to how age is calculated or coverage tiers are mapped must be applied in both functions. |

```elixir
defmodule Healthcare.EligibilityChecker do
  @moduledoc """
  Evaluates patient eligibility for health screenings and clinical trial
  enrolment based on age, insurance coverage, and medical history.
  """

  alias Healthcare.{Patient, Coverage, ClinicalTrial, Screening, Repo}

  @coverage_tier_weights %{basic: 1, standard: 2, premium: 3, government: 2}

  # ---------------------------------------------------------------------------
  # Screening eligibility
  # ---------------------------------------------------------------------------

  @doc """
  Determines whether a patient is eligible for the requested screening
  programme. Returns `{:ok, :eligible}` or `{:error, reason}`.
  """
  def check_screening_eligibility(%Patient{} = patient, %Screening{} = screening) do
    with {:ok, history} <- Repo.fetch_medical_history(patient.id) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the age calculation and
      # coverage-tier resolution are copy-pasted identically into
      # check_trial_eligibility/2. A change to how age or tier is
      # computed must be applied in both functions.
      today      = Date.utc_today()
      age_years  = Date.diff(today, patient.date_of_birth) |> div(365)

      coverage = Repo.get_active_coverage(patient.id)

      coverage_tier =
        case coverage do
          nil                         -> :none
          %Coverage{type: t, active: true} -> Map.get(@coverage_tier_weights, t, 0)
          _                           -> 0
        end
      # VALIDATION: SMELL END

      cond do
        age_years < screening.min_age ->
          {:error, {:ineligible, :below_minimum_age}}

        age_years > screening.max_age ->
          {:error, {:ineligible, :above_maximum_age}}

        coverage_tier == :none and screening.requires_coverage ->
          {:error, {:ineligible, :no_active_coverage}}

        is_integer(coverage_tier) and coverage_tier < screening.min_coverage_tier ->
          {:error, {:ineligible, :insufficient_coverage}}

        history.contraindications != [] and
            Enum.any?(history.contraindications, &(&1 in screening.exclusion_conditions)) ->
          {:error, {:ineligible, :contraindication}}

        true ->
          {:ok, :eligible}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Clinical trial eligibility
  # ---------------------------------------------------------------------------

  @doc """
  Determines whether a patient meets the enrolment criteria for a clinical
  trial. Returns `{:ok, :eligible}` or `{:error, reason}`.
  """
  def check_trial_eligibility(%Patient{} = patient, %ClinicalTrial{} = trial) do
    with {:ok, history} <- Repo.fetch_medical_history(patient.id) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the same age-and-coverage
      # resolution block from check_screening_eligibility/2 is reproduced
      # here verbatim. If the age calculation or coverage mapping changes,
      # both functions must be updated.
      today      = Date.utc_today()
      age_years  = Date.diff(today, patient.date_of_birth) |> div(365)

      coverage = Repo.get_active_coverage(patient.id)

      coverage_tier =
        case coverage do
          nil                               -> :none
          %Coverage{type: t, active: true} -> Map.get(@coverage_tier_weights, t, 0)
          _                                 -> 0
        end
      # VALIDATION: SMELL END

      cond do
        age_years < trial.min_age ->
          {:error, {:ineligible, :below_minimum_age}}

        age_years > trial.max_age ->
          {:error, {:ineligible, :above_maximum_age}}

        trial.requires_coverage and coverage_tier == :none ->
          {:error, {:ineligible, :no_active_coverage}}

        history.prior_diagnoses == [] and trial.requires_diagnosis ->
          {:error, {:ineligible, :no_qualifying_diagnosis}}

        Enum.any?(trial.exclusion_conditions, &(&1 in history.contraindications)) ->
          {:error, {:ineligible, :contraindication}}

        history.active_medications != [] and
            Enum.any?(history.active_medications, &(&1 in trial.excluded_medications)) ->
          {:error, {:ineligible, :excluded_medication}}

        true ->
          {:ok, :eligible}
      end
    end
  end
end
```
