# Annotated Bad Example 24: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Healthcare.PatientRegistry.format_patient_ref/2`
- **Affected function(s)**: `format_patient_ref/2`
- **Short explanation**: The function calls `to_string/1` on `patient_id` to compose the patient reference string. There is no guard clause on the type of `patient_id`. In a healthcare system, patient IDs are expected to be either integers (auto-increment PKs) or UUIDs (binaries), but the function silently accepts floats, atoms, or any `String.Chars`-implementing type. Passing a float produces a scientific-notation string (e.g., `"1.0e3"`), which would be stored as a patient reference and could cause record-matching failures downstream. Maps and lists still raise `Protocol.UndefinedError` with no boundary error.

## Code

```elixir
defmodule Healthcare.PatientRegistry do
  @moduledoc """
  Manages patient identity records including reference code generation,
  demographic validation, and identifier look-up for the healthcare platform.

  Patient references follow the pattern `{FACILITY_CODE}-{YEAR}-{ID}`,
  e.g. `HOS01-2025-000842`.
  """

  @ref_separator "-"
  @id_pad_length 6
  @current_year Date.utc_today().year()
  @valid_blood_types ~w(A+ A- B+ B- AB+ AB- O+ O-)
  @valid_sex_values ~w(male female other undisclosed)

  @doc """
  Formats a patient reference code from a facility code and patient ID.

  ## Parameters
    - `facility_code`: A binary facility identifier, e.g. `"HOS01"`.
    - `patient_id`: The patient's database identifier (integer or UUID string).
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is invoked on `patient_id`
  # without any guard clause. The `String.Chars` protocol is not implemented for
  # `Map`, `List`, or `Tuple`, so those types raise `Protocol.UndefinedError` at
  # runtime. More dangerously, passing a `Float` (e.g., `1000.0`) silently produces
  # a scientific-notation reference like `"HOS01-2025-1.0e3"`, which would be
  # stored in the medical record system and break downstream patient-matching logic.
  # The function should guard with `is_integer(patient_id) or is_binary(patient_id)`.
  def format_patient_ref(facility_code, patient_id) when is_binary(facility_code) do
    id_str =
      patient_id
      |> to_string()
      |> String.pad_leading(@id_pad_length, "0")

    Enum.join(
      [String.upcase(facility_code), @current_year, id_str],
      @ref_separator
    )
  end
  # VALIDATION: SMELL END

  @doc """
  Validates a patient's demographic record map.
  Returns `:ok` or `{:error, {field, reason}}`.
  """
  def validate_demographics(%{
        first_name: first_name,
        last_name: last_name,
        date_of_birth: dob,
        sex: sex
      })
      when is_binary(first_name) and is_binary(last_name) and is_binary(sex) do
    cond do
      String.length(String.trim(first_name)) < 1 ->
        {:error, {:first_name, :blank}}

      String.length(String.trim(last_name)) < 1 ->
        {:error, {:last_name, :blank}}

      sex not in @valid_sex_values ->
        {:error, {:sex, :invalid_value}}

      not valid_date_of_birth?(dob) ->
        {:error, {:date_of_birth, :invalid_or_future}}

      true ->
        :ok
    end
  end

  def validate_demographics(_), do: {:error, {:record, :missing_required_fields}}

  @doc """
  Validates a blood type string against the accepted values.
  """
  def validate_blood_type(blood_type) when is_binary(blood_type) do
    if blood_type in @valid_blood_types do
      :ok
    else
      {:error, :invalid_blood_type}
    end
  end

  @doc """
  Returns the patient's age in years given a date of birth.
  """
  def age_in_years(%Date{} = dob) do
    today = Date.utc_today()
    years = today.year - dob.year

    if {today.month, today.day} < {dob.month, dob.day} do
      years - 1
    else
      years
    end
  end

  @doc """
  Checks whether two patient records likely refer to the same individual
  based on name and date of birth.
  """
  def probable_match?(
        %{first_name: fn1, last_name: ln1, date_of_birth: dob1},
        %{first_name: fn2, last_name: ln2, date_of_birth: dob2}
      ) do
    String.downcase(fn1) == String.downcase(fn2) and
      String.downcase(ln1) == String.downcase(ln2) and
      dob1 == dob2
  end

  defp valid_date_of_birth?(%Date{} = dob) do
    Date.compare(dob, Date.utc_today()) == :lt
  end

  defp valid_date_of_birth?(_), do: false
end
```
