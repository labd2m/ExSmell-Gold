# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `parse_subscription_response/2` function
- **Affected function(s):** `parse_subscription_response/2`
- **Short explanation:** The function handles every possible outcome of a subscription-creation API call — active, trialing, past_due, incomplete, canceled, payment-method failures, proration errors, plan-not-found — all in one deeply nested `case` expression. Centralising all this branching in a single function inflates cyclomatic complexity and creates a single point of failure for every caller.

---

```elixir
defmodule Billing.SubscriptionClient do
  @moduledoc """
  HTTP client for the subscription management platform.
  Covers plan creation, upgrades, downgrades, cancellation, and billing cycle
  queries. Wraps a Stripe-like subscription API.
  """

  require Logger

  @base_url "https://subscriptions.billing-platform.io/v2"

  def create_subscription(account_id, plan_id, payment_method_id, opts \\ []) do
    trial_days = Keyword.get(opts, :trial_days, 0)
    coupon_code = Keyword.get(opts, :coupon_code)
    billing_cycle_anchor = Keyword.get(opts, :billing_cycle_anchor)
    metadata = Keyword.get(opts, :metadata, %{})
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      account_id: account_id,
      plan_id: plan_id,
      payment_method_id: payment_method_id,
      trial_period_days: trial_days,
      coupon_code: coupon_code,
      billing_cycle_anchor: billing_cycle_anchor,
      metadata: metadata
    }

    case http_post("#{@base_url}/subscriptions", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        parse_subscription_response(raw, %{account_id: account_id, plan_id: plan_id})

      {:error, :timeout} ->
        {:error, :platform_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def cancel_subscription(subscription_id, opts \\ []) do
    at_period_end = Keyword.get(opts, :at_period_end, true)

    payload = %{cancel_at_period_end: at_period_end}

    case http_patch("#{@base_url}/subscriptions/#{subscription_id}", payload, build_headers()) do
      {:ok, %{status: 200, body: %{"status" => "canceled", "canceled_at" => ts}}} ->
        {:ok, %{subscription_id: subscription_id, status: :canceled, canceled_at: ts}}

      {:ok, %{status: 200, body: %{"status" => "active", "cancel_at" => ts}}} ->
        {:ok, %{subscription_id: subscription_id, status: :canceling_at_period_end, cancel_at: ts}}

      {:ok, %{status: 404}} ->
        {:error, :subscription_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def change_plan(subscription_id, new_plan_id, opts \\ []) do
    prorate = Keyword.get(opts, :prorate, true)
    payload = %{plan_id: new_plan_id, prorate: prorate}

    case http_patch("#{@base_url}/subscriptions/#{subscription_id}/plan", payload, build_headers()) do
      {:ok, %{status: 200, body: %{"subscription_id" => sid, "plan_id" => pid}}} ->
        {:ok, %{subscription_id: sid, new_plan_id: pid}}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        {:error, {:bad_request, msg}}

      {:ok, %{status: 404}} ->
        {:error, :subscription_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `parse_subscription_response/2` is the
  # single function responsible for every HTTP status and body variant returned
  # by the subscription creation endpoint. The 200 path fans out over active,
  # trialing, past_due, and incomplete body shapes — each with different keys.
  # The 400 path branches across payment_method_declined, invalid_coupon,
  # plan_not_found, trial_not_allowed, and generic errors. Additional arms cover
  # idempotency conflicts (409), proration errors (422), and multiple server
  # error shapes. All in one function, making it very long, hard to test per
  # branch, and fragile: a missing field in any pattern raises a MatchError that
  # prevents all other response types from being processed.
  defp parse_subscription_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "active",
            "subscription_id" => sid,
            "current_period_end" => period_end,
            "plan_id" => pid,
            "amount_cents" => amount
          } ->
            {:ok,
             %{
               subscription_id: sid,
               status: :active,
               plan_id: pid,
               current_period_end: period_end,
               amount_cents: amount,
               trial_end: nil
             }}

          %{"status" => "trialing", "subscription_id" => sid, "trial_end" => trial_end, "plan_id" => pid} ->
            Logger.info("Subscription trialing context=#{inspect(context)} trial_end=#{trial_end}")

            {:ok,
             %{
               subscription_id: sid,
               status: :trialing,
               plan_id: pid,
               current_period_end: trial_end,
               amount_cents: 0,
               trial_end: trial_end
             }}

          %{
            "status" => "past_due",
            "subscription_id" => sid,
            "last_payment_error" => error,
            "plan_id" => pid
          } ->
            Logger.warning("Subscription past_due context=#{inspect(context)} error=#{error}")

            {:ok,
             %{
               subscription_id: sid,
               status: :past_due,
               plan_id: pid,
               last_payment_error: error,
               amount_cents: nil,
               trial_end: nil
             }}

          %{
            "status" => "incomplete",
            "subscription_id" => sid,
            "action_required" => action,
            "action_url" => url
          } ->
            {:ok,
             %{
               subscription_id: sid,
               status: :incomplete,
               action_required: action,
               action_url: url
             }}

          %{"status" => unknown} ->
            {:error, {:unknown_subscription_status, unknown}}

          _ ->
            {:error, :malformed_subscription_body}
        end

      %{status: 201, body: %{"subscription_id" => sid, "status" => "active"}} ->
        {:ok, %{subscription_id: sid, status: :active}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "payment_method_declined", "decline_code" => code} ->
            {:error, {:payment_method_declined, code}}

          %{"error" => "payment_method_not_found"} ->
            {:error, :payment_method_not_found}

          %{"error" => "invalid_coupon", "coupon_code" => coupon} ->
            {:error, {:invalid_coupon, coupon}}

          %{"error" => "coupon_expired", "expired_at" => ts} ->
            {:error, {:coupon_expired, ts}}

          %{"error" => "plan_not_found", "plan_id" => pid} ->
            {:error, {:plan_not_found, pid}}

          %{"error" => "trial_not_allowed"} ->
            {:error, :trial_not_allowed}

          %{"error" => "account_already_subscribed", "existing_id" => eid} ->
            {:error, {:already_subscribed, eid}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("Subscription platform unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 402, body: %{"error" => "insufficient_funds"}} ->
        {:error, :insufficient_funds}

      %{status: 409, body: %{"error" => "idempotency_conflict", "existing_id" => eid}} ->
        {:error, {:idempotency_conflict, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 422, body: %{"error" => "proration_error", "detail" => detail}} ->
        {:error, {:proration_error, detail}}

      %{status: 422, body: %{"error" => msg}} ->
        {:error, {:unprocessable, msg}}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid}} ->
        Logger.error("Billing platform 500 request_id=#{rid} context=#{inspect(context)}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled subscription response status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp build_headers(idempotency_key \\ nil) do
    base = [
      {"Authorization", "Bearer #{System.get_env("BILLING_API_KEY", "")}"},
      {"Content-Type", "application/json"}
    ]

    if idempotency_key,
      do: [{"Idempotency-Key", idempotency_key} | base],
      else: base
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_patch(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
