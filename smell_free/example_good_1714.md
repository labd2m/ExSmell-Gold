```elixir
defmodule Payments.RefundPolicy do
  @moduledoc """
  Evaluates eligibility and computes refund amounts for completed orders
  based on elapsed time, order type, and subscription plan.
  """

  @type order_type :: :physical | :digital | :subscription
  @type plan :: :free | :standard | :premium
  @type order :: %{
    id: String.t(),
    type: order_type(),
    total_cents: pos_integer(),
    completed_at: DateTime.t(),
    plan: plan()
  }
  @type refund_decision :: %{eligible: boolean(), amount_cents: non_neg_integer(), reason: String.t()}

  @spec evaluate(order()) :: refund_decision()
  def evaluate(%{type: type, completed_at: completed_at, plan: plan, total_cents: total} = _order) do
    age_hours = hours_since(completed_at)
    window_hours = refund_window(type, plan)

    if age_hours <= window_hours do
      amount = compute_amount(type, total, age_hours, window_hours)
      %{eligible: true, amount_cents: amount, reason: "Within #{window_hours}h refund window"}
    else
      %{eligible: false, amount_cents: 0, reason: "Refund window of #{window_hours}h has expired"}
    end
  end

  @spec batch_evaluate([order()]) :: [%{order_id: String.t(), decision: refund_decision()}]
  def batch_evaluate(orders) when is_list(orders) do
    Enum.map(orders, fn order ->
      %{order_id: order.id, decision: evaluate(order)}
    end)
  end

  @spec eligible_total([order()]) :: non_neg_integer()
  def eligible_total(orders) when is_list(orders) do
    orders
    |> Enum.map(&evaluate/1)
    |> Enum.filter(& &1.eligible)
    |> Enum.sum_by(& &1.amount_cents)
  end

  @spec refund_window(order_type(), plan()) :: pos_integer()
  defp refund_window(:physical, :premium), do: 720
  defp refund_window(:physical, :standard), do: 336
  defp refund_window(:physical, :free), do: 168
  defp refund_window(:digital, :premium), do: 48
  defp refund_window(:digital, :standard), do: 24
  defp refund_window(:digital, :free), do: 0
  defp refund_window(:subscription, _plan), do: 24

  @spec compute_amount(order_type(), pos_integer(), float(), pos_integer()) :: non_neg_integer()
  defp compute_amount(:digital, total, _age, _window), do: total

  defp compute_amount(:physical, total, age_hours, window_hours) do
    elapsed_ratio = age_hours / window_hours
    proration = 1.0 - elapsed_ratio * 0.5
    round(total * max(proration, 0.5))
  end

  defp compute_amount(:subscription, total, age_hours, window_hours) do
    unused_ratio = 1.0 - age_hours / window_hours
    round(total * max(unused_ratio, 0.0))
  end

  @spec hours_since(DateTime.t()) :: float()
  defp hours_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :second) / 3600.0
  end
end
```
