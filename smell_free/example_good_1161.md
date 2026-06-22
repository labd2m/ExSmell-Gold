```elixir
defmodule Billing.SubscriptionCalculator do
  @moduledoc """
  Pure functional module for computing subscription charges, proration
  credits, and invoice line items.

  All functions are stateless and side-effect free. No process abstraction
  is used since the module manages no shared state and requires no
  concurrency. Callers receive consistent typed results for every input
  combination.
  """

  @type plan :: :starter | :growth | :enterprise
  @type billing_cycle :: :monthly | :annual
  @type seat_count :: pos_integer()

  @type line_item :: %{
          description: String.t(),
          quantity: pos_integer(),
          unit_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @type invoice :: %{
          line_items: [line_item()],
          subtotal_cents: non_neg_integer(),
          discount_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @plan_base_prices %{
    starter: %{monthly: 2_900, annual: 29_900},
    growth: %{monthly: 7_900, annual: 79_900},
    enterprise: %{monthly: 24_900, annual: 249_900}
  }

  @seat_price_cents 500
  @annual_discount_rate 0.15

  @doc """
  Computes a full invoice for the given plan, billing cycle, and seat count.

  Returns `{:error, :unknown_plan}` when `plan` is not a recognized atom.
  """
  @spec compute_invoice(plan(), billing_cycle(), seat_count()) ::
          {:ok, invoice()} | {:error, :unknown_plan}
  def compute_invoice(plan, cycle, seats)
      when is_atom(plan) and is_atom(cycle) and is_integer(seats) and seats > 0 do
    with {:ok, base_cents} <- base_price(plan, cycle) do
      base_item = build_line_item("#{plan_label(plan)} plan (#{cycle})", 1, base_cents)
      seat_item = build_line_item("Additional seats", seats, @seat_price_cents)
      line_items = [base_item, seat_item]
      subtotal = sum_totals(line_items)
      discount = annual_discount(subtotal, cycle)

      {:ok, %{
        line_items: line_items,
        subtotal_cents: subtotal,
        discount_cents: discount,
        total_cents: subtotal - discount
      }}
    end
  end

  @doc """
  Computes a prorated credit when upgrading mid-cycle.

  `days_remaining` is the number of calendar days left in the current period.
  """
  @spec proration_credit(plan(), billing_cycle(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :unknown_plan}
  def proration_credit(plan, cycle, days_remaining)
      when is_integer(days_remaining) and days_remaining > 0 do
    with {:ok, total_cents} <- base_price(plan, cycle) do
      daily_rate = total_cents / cycle_days(cycle)
      {:ok, round(daily_rate * days_remaining)}
    end
  end

  @doc "Formats a cent integer as a display string, e.g. `USD 12.99`."
  @spec format_cents(non_neg_integer(), String.t()) :: String.t()
  def format_cents(cents, currency \\ "USD")
      when is_integer(cents) and cents >= 0 and is_binary(currency) do
    "#{currency} #{div(cents, 100)}.#{String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")}"
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp base_price(plan, cycle) do
    case get_in(@plan_base_prices, [plan, cycle]) do
      nil -> {:error, :unknown_plan}
      price -> {:ok, price}
    end
  end

  defp build_line_item(description, quantity, unit_cents) do
    %{description: description, quantity: quantity, unit_cents: unit_cents,
      total_cents: quantity * unit_cents}
  end

  defp sum_totals(items), do: Enum.reduce(items, 0, fn i, acc -> acc + i.total_cents end)

  defp annual_discount(_subtotal, :monthly), do: 0
  defp annual_discount(subtotal, :annual), do: round(subtotal * @annual_discount_rate)

  defp plan_label(:starter), do: "Starter"
  defp plan_label(:growth), do: "Growth"
  defp plan_label(:enterprise), do: "Enterprise"

  defp cycle_days(:monthly), do: 30
  defp cycle_days(:annual), do: 365
end
```
