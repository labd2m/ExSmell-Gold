```elixir
defmodule Payments.CurrencyUtils do
  @moduledoc """
  Currency conversion and formatting helpers for the payments context.
  Used across invoicing, reporting, and checkout summary rendering.
  """

  @cents_per_unit 100

  defmacro cents_to_float(cents) do
    quote do
      unquote(cents) / unquote(@cents_per_unit)
    end
  end

  @doc """
  Converts a float amount to integer cents, rounding to the nearest cent.
  """
  @spec float_to_cents(float()) :: integer()
  def float_to_cents(amount) when is_float(amount) do
    round(amount * @cents_per_unit)
  end

  @doc """
  Formats an integer cent amount as a locale-style string.
  e.g. 10_050 -> "100.50"
  """
  @spec format_cents(integer()) :: String.t()
  def format_cents(cents) when is_integer(cents) do
    whole = div(abs(cents), @cents_per_unit)
    frac = rem(abs(cents), @cents_per_unit) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{whole}.#{frac}"
  end

  @doc """
  Converts between two currencies using a provided exchange rate.
  The rate is expressed as `target_per_source` (e.g. 1.08 USD per EUR).
  """
  @spec convert(integer(), float()) :: integer()
  def convert(cents, exchange_rate) when is_integer(cents) and is_float(exchange_rate) do
    round(cents * exchange_rate)
  end
end

defmodule Payments.RefundCalculator do
  @moduledoc """
  Computes refund amounts for various refund policies: full, partial,
  prorated, and restocking-fee-adjusted refunds.
  """

  require Payments.CurrencyUtils

  alias Payments.CurrencyUtils

  @restocking_fee_rate 0.15
  @min_refund_cents 100

  @doc """
  Calculates a full refund amount for a given order total.
  Returns the refund in cents.
  """
  @spec full_refund(integer()) :: integer()
  def full_refund(order_total_cents), do: order_total_cents

  @doc """
  Calculates a partial refund based on a percentage (0.0–1.0) of the total.
  """
  @spec partial_refund(integer(), float()) :: integer()
  def partial_refund(order_total_cents, rate) when rate >= 0.0 and rate <= 1.0 do
    round(order_total_cents * rate)
  end

  @doc """
  Calculates a prorated refund based on unused days out of a subscription period.
  """
  @spec prorated_refund(integer(), non_neg_integer(), pos_integer()) :: integer()
  def prorated_refund(total_cents, days_remaining, total_days) when total_days > 0 do
    round(total_cents * days_remaining / total_days)
  end

  @doc """
  Calculates refund after deducting a restocking fee, enforcing a minimum refund.
  Returns a map with the breakdown in both cents and float display values.
  """
  @spec restocking_adjusted_refund(integer()) :: map()
  def restocking_adjusted_refund(order_total_cents) do
    fee = round(order_total_cents * @restocking_fee_rate)
    net = max(order_total_cents - fee, @min_refund_cents)

    %{
      original_cents: order_total_cents,
      restocking_fee_cents: fee,
      refund_cents: net,
      original_display: CurrencyUtils.cents_to_float(order_total_cents),
      restocking_fee_display: CurrencyUtils.cents_to_float(fee),
      refund_display: CurrencyUtils.cents_to_float(net),
      formatted_refund: CurrencyUtils.format_cents(net)
    }
  end

  @doc """
  Returns true if the refund amount meets the minimum threshold.
  """
  @spec eligible?(integer()) :: boolean()
  def eligible?(refund_cents), do: refund_cents >= @min_refund_cents
end
```
