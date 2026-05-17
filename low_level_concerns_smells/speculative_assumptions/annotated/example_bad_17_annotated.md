# Annotated Example 17

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Billing.SubscriptionPlanCodeParser.decode/1`
- **Affected function(s):** `decode/1`
- **Short explanation:** The function splits a subscription plan code on `"-"` and extracts
  tier, billing cycle, and seat limit at fixed positions using `Enum.at/2`. The unplanned
  assumption is that tier names are single tokens. Legacy plan codes in the system use
  hyphenated tier names such as `"ENTERPRISE-PLUS"` or `"SMALL-TEAM"`. When such codes appear,
  the indices shift and the function silently reads the wrong tokens for billing cycle and seat
  limit — returning a plausible struct whose numeric seat limit may even parse successfully —
  instead of crashing and alerting the billing pipeline.

---

```elixir
defmodule Billing.SubscriptionPlanCodeParser do
  @moduledoc """
  Decodes subscription plan codes used in the billing and provisioning pipeline.

  Plan codes are stored in Stripe's product metadata and are used by the
  provisioning service to determine feature gates, seat limits, and billing
  cadence for each subscribing organisation.

  Format:
    "<TIER>-<BILLING_CYCLE>-<MAX_SEATS>"

  Examples:
    "STARTER-MONTHLY-5"
    "PROFESSIONAL-ANNUAL-25"
    "ENTERPRISE-ANNUAL-UNLIMITED"
    "TEAM-MONTHLY-10"
  """

  require Logger

  @known_tiers          ~w(STARTER TEAM PROFESSIONAL ENTERPRISE ENTERPRISE-PLUS SMALL-TEAM)
  @known_billing_cycles ~w(MONTHLY ANNUAL)
  @unlimited_sentinel   "UNLIMITED"

  defstruct [:tier, :billing_cycle, :max_seats, :unlimited_seats?, :raw]

  @doc """
  Decodes a plan code string into a `%SubscriptionPlanCodeParser{}` struct.

  Returns `{:ok, struct}` on success, or `{:error, reason}` if the billing
  cycle token is not recognised.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `decode/1` splits on "-" and uses `Enum.at/2`
  # VALIDATION: at positions 0, 1, 2 to extract tier, billing cycle, and seat limit.
  # VALIDATION: Legacy codes with hyphenated tiers such as "ENTERPRISE-PLUS-ANNUAL-50"
  # VALIDATION: split into ["ENTERPRISE", "PLUS", "ANNUAL", "50"]. `Enum.at(parts, 0)`
  # VALIDATION: returns "ENTERPRISE", `Enum.at(parts, 1)` returns "PLUS" (treated as the
  # VALIDATION: billing cycle), and `Enum.at(parts, 2)` returns "ANNUAL" (treated as seat
  # VALIDATION: limit). Billing cycle validation then fails for "PLUS", but for a code like
  # VALIDATION: "SMALL-TEAM-MONTHLY-10", `Enum.at(parts, 1)` returns "TEAM", which also
  # VALIDATION: fails validation — masking the real format mismatch behind an "unknown
  # VALIDATION: billing cycle" error instead of a "malformed plan code" error, making
  # VALIDATION: debugging misleading. For ambiguous cases the function returns wrong values
  # VALIDATION: silently without crashing.
  def decode(code) when is_binary(code) do
    parts         = String.split(code, "-")
    tier          = Enum.at(parts, 0)
    billing_cycle = Enum.at(parts, 1)
    raw_seats     = Enum.at(parts, 2)

    with :ok <- validate_billing_cycle(billing_cycle) do
      {unlimited?, max_seats} = parse_seat_limit(raw_seats)

      {:ok, %__MODULE__{
        tier:             tier,
        billing_cycle:    billing_cycle,
        max_seats:        max_seats,
        unlimited_seats?: unlimited?,
        raw:              code
      }}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the monthly equivalent price for a decoded plan.

  Prices are sourced from the application's plan configuration registry.
  """
  def monthly_price(%__MODULE__{tier: tier, billing_cycle: "MONTHLY"}) do
    plan_price_registry()[tier]
  end

  def monthly_price(%__MODULE__{tier: tier, billing_cycle: "ANNUAL"}) do
    case plan_price_registry()[tier] do
      nil   -> nil
      price -> Float.round(price * 10, 2)   # 2 months free on annual
    end
  end

  def monthly_price(_), do: nil

  @doc """
  Returns true if the plan allows unlimited seats.
  """
  def unlimited?(%__MODULE__{unlimited_seats?: true}), do: true
  def unlimited?(_), do: false

  @doc """
  Returns true if a given seat count is within the plan's allowed limit.
  """
  def seats_available?(%__MODULE__{unlimited_seats?: true}, _requested), do: true

  def seats_available?(%__MODULE__{max_seats: max}, requested)
      when is_integer(max) and is_integer(requested) do
    requested <= max
  end

  def seats_available?(_, _), do: false

  @doc """
  Formats a plan code struct into a human-readable plan label.
  """
  def display_label(%__MODULE__{tier: tier, billing_cycle: cycle, unlimited_seats?: true}) do
    "#{String.capitalize(tier)} — #{String.capitalize(cycle)} (Unlimited seats)"
  end

  def display_label(%__MODULE__{tier: tier, billing_cycle: cycle, max_seats: seats}) do
    "#{String.capitalize(tier)} — #{String.capitalize(cycle)} (up to #{seats} seats)"
  end

  @doc """
  Returns all known tier names supported by the billing platform.
  """
  def known_tiers, do: @known_tiers

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_billing_cycle(cycle) when is_binary(cycle) do
    if String.upcase(cycle) in @known_billing_cycles do
      :ok
    else
      {:error, {:unknown_billing_cycle, cycle, @known_billing_cycles}}
    end
  end

  defp validate_billing_cycle(nil), do: {:error, :missing_billing_cycle}
  defp validate_billing_cycle(_),   do: {:error, :invalid_billing_cycle}

  defp parse_seat_limit(@unlimited_sentinel), do: {true, nil}

  defp parse_seat_limit(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {false, n}
      _                  -> {false, nil}
    end
  end

  defp parse_seat_limit(nil), do: {false, nil}

  defp plan_price_registry do
    %{
      "STARTER"      => 29.00,
      "TEAM"         => 79.00,
      "PROFESSIONAL" => 149.00,
      "ENTERPRISE"   => 499.00
    }
  end
end
```
