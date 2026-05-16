# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `PremiumCalculator.quote/3`, where `coverage_amount` is passed to `Decimal.mult/2`
- **Affected function(s):** `quote/3`
- **Short explanation:** The `coverage_amount` parameter is passed directly to `Decimal.mult/2` via `Decimal.new/1` coercion without first checking that it is a numeric type or a valid numeric string. If a caller passes a map or an atom (e.g., coming from a partially-parsed policy form), `Decimal.new/1` raises a `Decimal.Error` deep inside the library, with no message identifying the `quote/3` function as the point where the invalid value was accepted.

```elixir
defmodule MyApp.Insurance.PremiumCalculator do
  @moduledoc """
  Calculates insurance premium quotes for life, health, property, and liability
  policies. Applies actuarial rate tables, risk adjustments, and discount schemes.
  """

  require Logger

  alias MyApp.Insurance.{
    ActuarialTable,
    RiskEngine,
    DiscountRegistry,
    PolicyQuoteRecord,
    UnderwritingRules
  }

  @rounding_precision 2
  @minimum_premium Decimal.new("10.00")
  @supported_policy_types [:life, :health, :property, :liability, :auto]

  @type quote_opts :: [
          term_years: pos_integer(),
          deductible: number(),
          discount_codes: [String.t()],
          riders: [atom()]
        ]

  @spec quote(String.t(), term(), String.t(), quote_opts()) ::
          {:ok, map()} | {:error, atom()}
  def quote(applicant_id, coverage_amount, policy_type, opts \\ []) do
    term_years = Keyword.get(opts, :term_years, 1)
    deductible = Keyword.get(opts, :deductible, 0)
    discount_codes = Keyword.get(opts, :discount_codes, [])
    riders = Keyword.get(opts, :riders, [])

    with :ok <- validate_policy_type(policy_type),
         {:ok, applicant} <- fetch_applicant_profile(applicant_id),
         {:ok, risk_score} <- RiskEngine.evaluate(applicant, policy_type),
         {:ok, rate_table} <- ActuarialTable.fetch(policy_type, applicant.age_band, risk_score) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `coverage_amount` is passed to
      # VALIDATION: `Decimal.new/1` without any type check at the boundary.
      # VALIDATION: Callers that forward this value from web forms or JSON APIs
      # VALIDATION: may pass a map like %{"amount" => 500000} or an atom.
      # VALIDATION: `Decimal.new/1` will raise a Decimal.Error deep inside the
      # VALIDATION: library with no trace back to the `quote/3` entry point.
      base_rate = Decimal.mult(Decimal.new(coverage_amount), rate_table.rate_per_unit)
      # VALIDATION: SMELL END

      term_factor = Decimal.new(to_string(:math.pow(rate_table.annual_multiplier, term_years)))
      gross_premium = Decimal.mult(base_rate, term_factor)

      deductible_credit =
        if deductible > 0 do
          Decimal.mult(gross_premium, Decimal.new(to_string(rate_table.deductible_factor)))
        else
          Decimal.new("0")
        end

      rider_charges =
        Enum.reduce(riders, Decimal.new("0"), fn rider, acc ->
          rider_rate = Map.get(rate_table.rider_rates, rider, Decimal.new("0"))
          Decimal.add(acc, rider_rate)
        end)

      pre_discount_premium =
        gross_premium
        |> Decimal.sub(deductible_credit)
        |> Decimal.add(rider_charges)

      discount_factor = compute_discount_factor(discount_codes)
      discount_amount = Decimal.mult(pre_discount_premium, discount_factor)

      final_premium =
        pre_discount_premium
        |> Decimal.sub(discount_amount)
        |> Decimal.max(@minimum_premium)
        |> Decimal.round(@rounding_precision)

      quote_record = %{
        applicant_id: applicant_id,
        policy_type: policy_type,
        coverage_amount: coverage_amount,
        term_years: term_years,
        risk_score: risk_score,
        gross_premium: Decimal.round(gross_premium, @rounding_precision),
        discount_amount: Decimal.round(discount_amount, @rounding_precision),
        final_annual_premium: final_premium,
        monthly_premium: Decimal.div(final_premium, Decimal.new("12")) |> Decimal.round(@rounding_precision),
        quoted_at: DateTime.utc_now(),
        valid_until: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      }

      {:ok, saved} = PolicyQuoteRecord.create(quote_record)

      Logger.info(
        "Premium quoted: applicant=#{applicant_id} type=#{policy_type} " <>
          "coverage=#{coverage_amount} premium=#{final_premium}"
      )

      {:ok, saved}
    end
  end

  @spec compare_quotes(String.t(), term(), [String.t()]) :: {:ok, [map()]}
  def compare_quotes(applicant_id, coverage_amount, policy_types) do
    results =
      Enum.map(policy_types, fn type ->
        case quote(applicant_id, coverage_amount, type) do
          {:ok, q} -> q
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.final_annual_premium)

    {:ok, results}
  end

  # Private helpers

  defp validate_policy_type(type) when type in @supported_policy_types, do: :ok
  defp validate_policy_type(_), do: {:error, :unsupported_policy_type}

  defp fetch_applicant_profile(applicant_id) do
    {:ok, %{id: applicant_id, age_band: :adult, health_score: 85, claims_history: []}}
  end

  defp compute_discount_factor(codes) do
    Enum.reduce(codes, Decimal.new("0"), fn code, acc ->
      case DiscountRegistry.fetch(code) do
        {:ok, discount} -> Decimal.add(acc, discount.rate)
        _ -> acc
      end
    end)
  end
end
```
