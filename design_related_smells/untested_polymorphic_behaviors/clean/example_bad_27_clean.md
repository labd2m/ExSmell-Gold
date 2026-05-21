```elixir
defmodule Subscriptions.PlanFormatter do
  @moduledoc """
  Provides formatting and normalization utilities for subscription plans.
  Used during plan creation, upgrade/downgrade flows, and invoice line-item
  generation in the subscription management system.
  """

  @slug_separator "-"
  @whitespace_pattern ~r/\s+/
  @invalid_slug_chars ~r/[^a-z0-9\-]/
  @max_slug_length 64

  @doc """
  Builds a URL-safe slug for a plan name.
  Used as the stable identifier in billing integrations and plan selection URLs.

  ## Examples

      iex> Subscriptions.PlanFormatter.build_plan_slug("Enterprise Pro")
      "enterprise-pro"

      iex> Subscriptions.PlanFormatter.build_plan_slug(:starter_monthly)
      "starter-monthly"
  """
  def build_plan_slug(plan_name) do
    plan_name
    |> to_string()
    |> String.downcase()
    |> String.replace(@whitespace_pattern, @slug_separator)
    |> String.replace("_", @slug_separator)
    |> String.replace(@invalid_slug_chars, "")
    |> String.slice(0, @max_slug_length)
  end

  @doc """
  Returns the display label for a plan billing interval.
  """
  def interval_label(:monthly), do: "per month"
  def interval_label(:quarterly), do: "per quarter"
  def interval_label(:annual), do: "per year"
  def interval_label(:lifetime), do: "one-time"

  @doc """
  Formats a plan's price and billing interval for display on pricing pages.
  """
  def format_price(amount_cents, currency, interval)
      when is_integer(amount_cents) and is_binary(currency) and is_atom(interval) do
    units = div(amount_cents, 100)
    cents = rem(amount_cents, 100)
    amount_str = "#{currency} #{units}.#{String.pad_leading("#{cents}", 2, "0")}"
    "#{amount_str} #{interval_label(interval)}"
  end

  @doc """
  Returns a short marketing label for a plan tier.
  """
  def tier_badge(:free), do: "Free"
  def tier_badge(:starter), do: "Starter"
  def tier_badge(:pro), do: "Pro"
  def tier_badge(:enterprise), do: "Enterprise"
  def tier_badge(_), do: "Custom"

  @doc """
  Builds the invoice line-item description for a subscription charge.
  """
  def invoice_line_description(plan_name, interval, period_start, period_end)
      when is_binary(plan_name) and is_atom(interval) do
    start_str = Date.to_iso8601(period_start)
    end_str = Date.to_iso8601(period_end)
    "#{plan_name} (#{interval_label(interval)}) — #{start_str} to #{end_str}"
  end

  @doc """
  Returns whether a plan slug is valid.
  """
  def valid_slug?(slug) when is_binary(slug) do
    String.length(slug) >= 2 and
      String.length(slug) <= @max_slug_length and
      Regex.match?(~r/^[a-z0-9][a-z0-9\-]*[a-z0-9]$/, slug)
  end

  def valid_slug?(_), do: false

  @doc """
  Sorts plans by tier order for display on the pricing page.
  """
  def sort_by_tier(plans) when is_list(plans) do
    tier_order = %{free: 0, starter: 1, pro: 2, enterprise: 3}

    Enum.sort_by(plans, fn plan ->
      Map.get(tier_order, plan.tier, 99)
    end)
  end
end
```
