```elixir
defmodule Billing.InvoiceBuilder do
  @moduledoc """
  Constructs invoice records from a subscription, a usage summary,
  and applicable discount rules.

  Building an invoice is a pure transformation: no side effects,
  no database calls. Persistence is the caller's responsibility.
  """

  alias Billing.Invoice
  alias Billing.LineItem
  alias Billing.Discount
  alias Billing.Subscription

  @type build_result :: {:ok, Invoice.t()} | {:error, :invalid_subscription | :no_line_items}

  @doc """
  Builds an invoice for the given subscription and usage data.

  Applies any active discounts and computes the final total.
  Returns `{:ok, invoice}` or an error if required data is missing.
  """
  @spec build(Subscription.t(), map(), [Discount.t()]) :: build_result()
  def build(%Subscription{status: :active} = subscription, usage_summary, discounts)
      when is_map(usage_summary) and is_list(discounts) do
    line_items = build_line_items(subscription, usage_summary)

    case line_items do
      [] ->
        {:error, :no_line_items}

      items ->
        subtotal_cents = sum_line_items(items)
        discount_cents = apply_discounts(subtotal_cents, discounts)
        total_cents = max(0, subtotal_cents - discount_cents)

        invoice = %Invoice{
          subscription_id: subscription.id,
          customer_id: subscription.customer_id,
          currency: subscription.currency,
          line_items: items,
          subtotal_cents: subtotal_cents,
          discount_cents: discount_cents,
          total_cents: total_cents,
          due_date: compute_due_date(subscription.billing_cycle_day)
        }

        {:ok, invoice}
    end
  end

  def build(%Subscription{}, _usage, _discounts), do: {:error, :invalid_subscription}

  @spec build_line_items(Subscription.t(), map()) :: [LineItem.t()]
  defp build_line_items(subscription, usage_summary) do
    base_item = base_plan_line_item(subscription)
    usage_items = usage_line_items(usage_summary, subscription.currency)
    [base_item | usage_items]
  end

  @spec base_plan_line_item(Subscription.t()) :: LineItem.t()
  defp base_plan_line_item(subscription) do
    %LineItem{
      description: "Base plan: #{subscription.plan_name}",
      quantity: 1,
      unit_price_cents: subscription.base_price_cents,
      total_cents: subscription.base_price_cents
    }
  end

  @spec usage_line_items(map(), String.t()) :: [LineItem.t()]
  defp usage_line_items(usage_summary, _currency) do
    usage_summary
    |> Enum.filter(fn {_metric, amount} -> amount > 0 end)
    |> Enum.map(&build_usage_line_item/1)
  end

  @spec build_usage_line_item({String.t(), number()}) :: LineItem.t()
  defp build_usage_line_item({metric, amount}) do
    unit_price = unit_price_for_metric(metric)
    total = round(amount * unit_price)

    %LineItem{
      description: "Usage: #{metric}",
      quantity: amount,
      unit_price_cents: unit_price,
      total_cents: total
    }
  end

  @spec unit_price_for_metric(String.t()) :: non_neg_integer()
  defp unit_price_for_metric("api_calls"), do: 1
  defp unit_price_for_metric("storage_gb"), do: 50
  defp unit_price_for_metric("seats"), do: 999
  defp unit_price_for_metric(_), do: 0

  @spec sum_line_items([LineItem.t()]) :: non_neg_integer()
  defp sum_line_items(items) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.total_cents end)
  end

  @spec apply_discounts(non_neg_integer(), [Discount.t()]) :: non_neg_integer()
  defp apply_discounts(subtotal_cents, discounts) do
    Enum.reduce(discounts, 0, fn discount, acc ->
      acc + compute_discount_amount(subtotal_cents, discount)
    end)
  end

  @spec compute_discount_amount(non_neg_integer(), Discount.t()) :: non_neg_integer()
  defp compute_discount_amount(subtotal_cents, %Discount{type: :percentage, value: pct}) do
    round(subtotal_cents * pct / 100)
  end

  defp compute_discount_amount(_subtotal_cents, %Discount{type: :fixed, value: amount}) do
    amount
  end

  @spec compute_due_date(1..28) :: Date.t()
  defp compute_due_date(billing_cycle_day) do
    today = Date.utc_today()
    %{today | day: billing_cycle_day} |> Date.add(30)
  end
end
```
