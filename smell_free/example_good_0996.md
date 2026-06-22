```elixir
defmodule MyApp.Billing.RefundCalculator do
  @moduledoc """
  Calculates the refundable amount for a return or cancellation given
  the original charge, any partial usage consumed, and the applicable
  refund policy. Policies are expressed as pure data; no process or
  I/O is involved in the calculation.

  The refund amount is always capped at the original charge to prevent
  over-refunds regardless of how a policy is configured.
  """

  @type policy :: %{
          required(:type) => :full | :prorated | :fixed | :none,
          optional(:rate_bps) => non_neg_integer(),
          optional(:fixed_amount_cents) => non_neg_integer(),
          optional(:no_refund_after_days) => pos_integer()
        }

  @type refund_result :: %{
          refund_cents: non_neg_integer(),
          original_charge_cents: pos_integer(),
          reason: String.t()
        }

  @doc """
  Calculates the refundable amount in cents given the `original_charge`,
  `days_since_charge`, and the applicable `policy`.
  """
  @spec calculate(pos_integer(), non_neg_integer(), policy()) :: refund_result()
  def calculate(original_charge_cents, days_since_charge, policy)
      when is_integer(original_charge_cents) and original_charge_cents > 0 and
             is_integer(days_since_charge) and days_since_charge >= 0 do
    if past_refund_window?(policy, days_since_charge) do
      %{refund_cents: 0, original_charge_cents: original_charge_cents,
        reason: "outside refund window"}
    else
      apply_policy(original_charge_cents, policy)
    end
  end

  @spec apply_policy(pos_integer(), policy()) :: refund_result()
  defp apply_policy(charge, %{type: :full}) do
    %{refund_cents: charge, original_charge_cents: charge, reason: "full refund"}
  end

  defp apply_policy(charge, %{type: :prorated, rate_bps: bps}) do
    amount = min(div(charge * bps, 10_000), charge)
    %{refund_cents: amount, original_charge_cents: charge, reason: "prorated at #{bps / 100.0}%"}
  end

  defp apply_policy(charge, %{type: :fixed, fixed_amount_cents: fixed}) do
    amount = min(fixed, charge)
    %{refund_cents: amount, original_charge_cents: charge, reason: "fixed refund of #{fixed} cents"}
  end

  defp apply_policy(charge, %{type: :none}) do
    %{refund_cents: 0, original_charge_cents: charge, reason: "non-refundable"}
  end

  defp apply_policy(charge, _policy) do
    %{refund_cents: 0, original_charge_cents: charge, reason: "unknown policy type"}
  end

  @spec past_refund_window?(policy(), non_neg_integer()) :: boolean()
  defp past_refund_window?(%{no_refund_after_days: limit}, days) when is_integer(limit),
    do: days > limit

  defp past_refund_window?(_policy, _days), do: false
end
```
