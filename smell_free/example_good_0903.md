# File: `example_good_903.md`

```elixir
defmodule Commerce.ReturnProcessor do
  @moduledoc """
  Authorises and processes product returns against a set of configurable
  return policy rules, computing refund amounts and generating return
  authorisation records.

  Policy evaluation is pure; persistence and refund issuance are
  delegated to injected adapters so this module remains testable in
  isolation.
  """

  @type order_id :: String.t()
  @type line_item_id :: String.t()
  @type amount_cents :: non_neg_integer()

  @type return_request :: %{
          required(:order_id) => order_id(),
          required(:line_items) => [%{id: line_item_id(), quantity: pos_integer()}],
          required(:reason) => String.t(),
          optional(:customer_note) => String.t()
        }

  @type return_policy :: %{
          required(:return_window_days) => pos_integer(),
          required(:restocking_fee_pct) => float(),
          required(:refundable_reasons) => :all | [String.t()],
          optional(:non_returnable_categories) => [String.t()]
        }

  @type authorisation :: %{
          authorised: boolean(),
          return_id: String.t() | nil,
          refund_cents: amount_cents(),
          restocking_fee_cents: amount_cents(),
          denial_reasons: [String.t()]
        }

  @doc """
  Evaluates a return request against `policy` and the order details
  fetched via `order_store`.

  Returns an `authorisation` describing whether the return is approved,
  the computed refund, and any denial reasons.
  """
  @spec authorise(return_request(), return_policy(), module()) :: authorisation()
  def authorise(%{} = request, %{} = policy, order_store) do
    case order_store.fetch(request.order_id) do
      {:error, :not_found} ->
        deny(["order not found"])

      {:ok, order} ->
        evaluate(request, policy, order)
    end
  end

  @doc """
  Calculates the refund amount for a set of line items after applying
  the restocking fee.
  """
  @spec compute_refund([map()], map(), float()) :: %{
          gross_cents: amount_cents(),
          fee_cents: amount_cents(),
          net_cents: amount_cents()
        }
  def compute_refund(order_line_items, return_line_items, restocking_fee_pct) do
    total =
      Enum.reduce(return_line_items, 0, fn ri, acc ->
        order_item = Enum.find(order_line_items, &(&1.id == ri.id))
        if order_item, do: acc + order_item.unit_price_cents * ri.quantity, else: acc
      end)

    fee = round(total * restocking_fee_pct / 100.0)
    %{gross_cents: total, fee_cents: fee, net_cents: max(total - fee, 0)}
  end

  defp evaluate(request, policy, order) do
    denial_reasons =
      []
      |> check_return_window(order, policy)
      |> check_reason(request.reason, policy)
      |> check_non_returnable_items(request.line_items, order, policy)

    if denial_reasons == [] do
      refund = compute_refund(order.line_items, request.line_items, policy.restocking_fee_pct)

      %{
        authorised: true,
        return_id: generate_return_id(),
        refund_cents: refund.net_cents,
        restocking_fee_cents: refund.fee_cents,
        denial_reasons: []
      }
    else
      deny(Enum.reverse(denial_reasons))
    end
  end

  defp check_return_window(errors, order, %{return_window_days: window}) do
    order_date = order.placed_at |> DateTime.to_date()
    days_since = Date.diff(Date.utc_today(), order_date)

    if days_since > window do
      ["return window of #{window} days has expired (#{days_since} days since purchase)" | errors]
    else
      errors
    end
  end

  defp check_reason(errors, _reason, %{refundable_reasons: :all}), do: errors

  defp check_reason(errors, reason, %{refundable_reasons: allowed}) do
    if reason in allowed do
      errors
    else
      ["return reason '#{reason}' is not eligible for a refund" | errors]
    end
  end

  defp check_non_returnable_items(errors, _line_items, _order, policy)
       when not is_map_key(policy, :non_returnable_categories), do: errors

  defp check_non_returnable_items(errors, return_items, order, %{non_returnable_categories: blocked}) do
    non_returnable =
      Enum.flat_map(return_items, fn ri ->
        order_item = Enum.find(order.line_items, &(&1.id == ri.id))
        if order_item && order_item.category in blocked do
          [order_item.name]
        else
          []
        end
      end)

    if non_returnable != [] do
      ["items not eligible for return: #{Enum.join(non_returnable, ", ")}" | errors]
    else
      errors
    end
  end

  defp deny(reasons) do
    %{authorised: false, return_id: nil, refund_cents: 0, restocking_fee_cents: 0, denial_reasons: reasons}
  end

  defp generate_return_id do
    "RMA-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
