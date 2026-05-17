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
