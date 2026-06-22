```elixir
defprotocol Billing.Priceable do
  @moduledoc """
  Protocol that any billable domain entity must implement
  to participate in invoice line-item generation.
  """

  @doc "Returns the unit price in cents for the given billable item."
  @spec unit_price(t()) :: pos_integer()
  def unit_price(item)

  @doc "Returns a human-readable description for the invoice line."
  @spec line_description(t()) :: String.t()
  def line_description(item)
end

defmodule Billing.Subscription do
  @moduledoc "Represents a recurring subscription plan."

  @type t :: %__MODULE__{
          plan_name: String.t(),
          monthly_price_cents: pos_integer(),
          seat_count: pos_integer()
        }

  defstruct [:plan_name, :monthly_price_cents, :seat_count]
end

defimpl Billing.Priceable, for: Billing.Subscription do
  def unit_price(%{monthly_price_cents: price, seat_count: seats}), do: price * seats

  def line_description(%{plan_name: name, seat_count: seats}) do
    "#{name} plan — #{seats} seat(s)"
  end
end

defmodule Billing.AddonService do
  @moduledoc "Represents a one-time or metered add-on service."

  @type t :: %__MODULE__{
          name: String.t(),
          units_consumed: non_neg_integer(),
          price_per_unit_cents: pos_integer()
        }

  defstruct [:name, :units_consumed, :price_per_unit_cents]
end

defimpl Billing.Priceable, for: Billing.AddonService do
  def unit_price(%{units_consumed: units, price_per_unit_cents: price}), do: units * price

  def line_description(%{name: name, units_consumed: units}) do
    "#{name} — #{units} unit(s) consumed"
  end
end

defmodule Billing.InvoiceBuilder do
  @moduledoc """
  Composes invoice line items from any collection of `Priceable` entities,
  computes subtotal, applies tax, and returns a structured invoice map.
  """

  alias Billing.Priceable

  @type line_item :: %{description: String.t(), amount_cents: pos_integer()}
  @type invoice :: %{
          line_items: [line_item()],
          subtotal_cents: non_neg_integer(),
          tax_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @tax_rate 0.08

  @spec build([Priceable.t()]) :: invoice()
  def build(items) when is_list(items) do
    line_items = Enum.map(items, &to_line_item/1)
    subtotal = Enum.sum(Enum.map(line_items, & &1.amount_cents))
    tax = round(subtotal * @tax_rate)

    %{
      line_items: line_items,
      subtotal_cents: subtotal,
      tax_cents: tax,
      total_cents: subtotal + tax
    }
  end

  @spec to_line_item(Priceable.t()) :: line_item()
  defp to_line_item(item) do
    %{
      description: Priceable.line_description(item),
      amount_cents: Priceable.unit_price(item)
    }
  end
end
```
