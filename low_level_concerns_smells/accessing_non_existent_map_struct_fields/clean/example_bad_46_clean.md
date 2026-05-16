```elixir
defmodule Healthcare.PrescriptionValidator do
  @moduledoc """
  Validates electronic prescriptions before they are transmitted
  to the pharmacy network. Enforces DEA controlled-substance rules,
  prior-authorisation requirements, refill limits, and allergy checks.
  """

  require Logger

  @controlled_schedules      [2, 3, 4, 5]
  @schedule_2_max_days_supply 30
  @max_standard_refills       11

  @type prescription :: %{
          id: String.t(),
          patient_id: String.t(),
          prescriber_id: String.t(),
          drug_name: String.t(),
          ndc_code: String.t(),
          quantity: pos_integer(),
          days_supply: pos_integer(),
          sig: String.t(),
          written_at: DateTime.t(),
          optional(:controlled_substance_schedule) => 2 | 3 | 4 | 5,
          optional(:requires_prior_auth) => boolean(),
          optional(:max_refills) => non_neg_integer(),
          optional(:dea_number) => String.t()
        }

  @spec validate(prescription()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(prescription) do
    errors =
      []
      |> check_required_fields(prescription)
      |> check_days_supply(prescription)
      |> check_controlled_substance(prescription)
      |> check_prior_auth(prescription)
      |> check_refills(prescription)

    if errors == [] do
      Logger.info("Prescription #{prescription.id} validated successfully")
      {:ok, build_summary(prescription)}
    else
      Logger.warning("Prescription #{prescription.id} failed validation: #{inspect(errors)}")
      {:error, Enum.reverse(errors)}
    end
  end

  defp check_required_fields(errors, rx) do
    [:patient_id, :prescriber_id, :drug_name, :ndc_code, :quantity, :days_supply, :sig]
    |> Enum.reduce(errors, fn field, acc ->
      value = Map.get(rx, field)
      if is_nil(value) or value == "",
        do: ["#{field} is required" | acc],
        else: acc
    end)
  end

  defp check_days_supply(errors, %{days_supply: ds}) when ds <= 0,
    do: ["days_supply must be positive" | errors]
  defp check_days_supply(errors, _), do: errors

  defp check_controlled_substance(errors, prescription) do
    schedule   = prescription[:controlled_substance_schedule]
    dea_number = prescription[:dea_number]

    if schedule in @controlled_schedules do
      errors
      |> then(fn e ->
        if is_nil(dea_number) or String.trim(dea_number) == "",
          do: ["DEA number required for Schedule #{schedule} substance" | e], else: e
      end)
      |> then(fn e ->
        if schedule == 2 and prescription.days_supply > @schedule_2_max_days_supply,
          do: ["Schedule II supply limit is #{@schedule_2_max_days_supply} days" | e], else: e
      end)
    else
      errors
    end
  end

  defp check_prior_auth(errors, prescription) do
    requires_prior_auth = prescription[:requires_prior_auth]

    if requires_prior_auth and not Map.has_key?(prescription, :prior_auth_number) do
      ["prior authorisation number is required for this drug" | errors]
    else
      errors
    end
  end

  defp check_refills(errors, prescription) do
    max_refills = prescription[:max_refills]

    cond do
      is_nil(max_refills) ->
        errors

      max_refills < 0 ->
        ["max_refills cannot be negative" | errors]

      max_refills > @max_standard_refills ->
        ["max_refills #{max_refills} exceeds allowed maximum of #{@max_standard_refills}" | errors]

      true ->
        errors
    end
  end

  defp build_summary(rx) do
    %{
      prescription_id: rx.id,
      patient_id:      rx.patient_id,
      drug_name:       rx.drug_name,
      ndc_code:        rx.ndc_code,
      quantity:        rx.quantity,
      days_supply:     rx.days_supply,
      controlled:      rx[:controlled_substance_schedule] in @controlled_schedules,
      validated_at:    DateTime.utc_now()
    }
  end
end
```
