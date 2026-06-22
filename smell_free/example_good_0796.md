```elixir
defmodule MyApp.Billing.UsageBasedPricer do
  @moduledoc """
  Calculates charges for usage-based billing tiers. Each product can
  define multiple pricing tiers — flat, per-unit, or volume — and this
  module selects and applies the correct tier for a given consumption
  quantity. All arithmetic is in integer cents to avoid floating-point
  drift across large invoices.

  Tier definitions are plain data structs, keeping the calculation logic
  entirely decoupled from the database and trivially testable.
  """

  @type tier_type :: :flat | :per_unit | :volume

  @type tier :: %{
          required(:type) => tier_type(),
          required(:up_to) => pos_integer() | :infinity,
          required(:unit_price_cents) => non_neg_integer(),
          optional(:flat_amount_cents) => non_neg_integer()
        }

  @type pricing_result :: %{
          quantity: non_neg_integer(),
          line_items: [%{description: String.t(), cents: non_neg_integer()}],
          total_cents: non_neg_integer()
        }

  @doc """
  Calculates the charge for `quantity` units against the ordered list of
  `tiers`. Tiers must be sorted by `:up_to` ascending with the final
  tier having `up_to: :infinity`.
  """
  @spec calculate(non_neg_integer(), [tier()]) :: pricing_result()
  def calculate(quantity, tiers) when is_integer(quantity) and quantity >= 0 and is_list(tiers) do
    {line_items, _remaining} =
      Enum.reduce(tiers, {[], quantity}, fn tier, {lines, remaining} ->
        if remaining <= 0 do
          {lines, 0}
        else
          {amount, used, line} = apply_tier(tier, remaining)
          {lines ++ [line], remaining - used}
        end
      end)

    total = Enum.sum_by(line_items, & &1.cents)
    %{quantity: quantity, line_items: line_items, total_cents: total}
  end

  @doc "Returns the average per-unit cost in cents across the entire quantity."
  @spec effective_unit_price(pricing_result()) :: float()
  def effective_unit_price(%{quantity: 0}), do: 0.0

  def effective_unit_price(%{quantity: qty, total_cents: total}) do
    Float.round(total / qty, 4)
  end

  @spec apply_tier(tier(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), %{description: String.t(), cents: non_neg_integer()}}
  defp apply_tier(%{type: :flat, flat_amount_cents: flat, up_to: up_to}, remaining) do
    used = tier_usage(up_to, remaining)
    line = %{description: "Flat fee (first #{used} units)", cents: flat}
    {flat, used, line}
  end

  defp apply_tier(%{type: :per_unit, unit_price_cents: unit_price, up_to: up_to}, remaining) do
    used = tier_usage(up_to, remaining)
    amount = used * unit_price
    line = %{description: "#{used} units × #{format_cents(unit_price)}", cents: amount}
    {amount, used, line}
  end

  defp apply_tier(%{type: :volume, unit_price_cents: unit_price, up_to: up_to}, remaining) do
    used = tier_usage(up_to, remaining)
    amount = remaining * unit_price
    line = %{description: "#{remaining} units at volume rate #{format_cents(unit_price)}", cents: amount}
    {amount, remaining, line}
  end

  @spec tier_usage(:infinity | pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp tier_usage(:infinity, remaining), do: remaining
  defp tier_usage(up_to, remaining), do: min(up_to, remaining)

  @spec format_cents(non_neg_integer()) :: String.t()
  defp format_cents(cents) do
    "$#{div(cents, 100)}.#{String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")}"
  end
end
```
