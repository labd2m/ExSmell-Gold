```elixir
defmodule MyApp.Billing.SubscriptionRenewal do
  @moduledoc """
  Processes subscription renewals at the end of each billing period.
  A renewal attempts to charge the customer's default payment method,
  advances the billing cycle on success, and transitions the subscription
  to `:past_due` on failure rather than cancelling immediately, giving
  the customer a grace period to update their payment details.

  Designed to be called from an Oban job scheduled at cycle end.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Billing.{Subscription, Payment, BillingCycle}
  alias MyApp.Payments.Gateway
  alias MyApp.Events

  @type renewal_result ::
          {:ok, :renewed}
          | {:ok, :past_due}
          | {:error, :no_payment_method}
          | {:error, term()}

  @doc """
  Attempts to renew `subscription`. Returns `{:ok, :renewed}` when the
  charge succeeds and the cycle advances, or `{:ok, :past_due}` when the
  charge fails and the subscription is marked for follow-up.
  """
  @spec renew(Subscription.t()) :: renewal_result()
  def renew(%Subscription{} = sub) do
    with :ok <- validate_renewable(sub),
         {:ok, method_id} <- fetch_default_payment_method(sub) do
      attempt_charge(sub, method_id)
    end
  end

  @spec validate_renewable(Subscription.t()) ::
          :ok | {:error, :not_active} | {:error, :not_due}
  defp validate_renewable(%Subscription{status: :active, current_period_end: ends_at}) do
    if DateTime.compare(ends_at, DateTime.utc_now()) != :gt, do: :ok, else: {:error, :not_due}
  end

  defp validate_renewable(_), do: {:error, :not_active}

  @spec fetch_default_payment_method(Subscription.t()) ::
          {:ok, String.t()} | {:error, :no_payment_method}
  defp fetch_default_payment_method(sub) do
    case sub.default_payment_method_id do
      nil -> {:error, :no_payment_method}
      id -> {:ok, id}
    end
  end

  @spec attempt_charge(Subscription.t(), String.t()) :: renewal_result()
  defp attempt_charge(sub, payment_method_id) do
    case Gateway.charge(sub.customer_id, sub.plan_price_cents, payment_method_id) do
      {:ok, charge_id} ->
        Multi.new()
        |> Multi.run(:payment, fn _repo, _ -> record_payment(sub, charge_id) end)
        |> Multi.run(:cycle, fn _repo, _ -> advance_cycle(sub) end)
        |> Repo.transaction()
        |> handle_success_transaction(sub)

      {:error, reason} ->
        mark_past_due(sub, reason)
    end
  end

  @spec handle_success_transaction({:ok, map()} | {:error, term()}, Subscription.t()) ::
          renewal_result()
  defp handle_success_transaction({:ok, _changes}, sub) do
    Events.broadcast(%Events.SubscriptionRenewed{
      subscription_id: sub.id,
      customer_id: sub.customer_id,
      occurred_at: DateTime.utc_now()
    })

    {:ok, :renewed}
  end

  defp handle_success_transaction({:error, reason}, _sub), do: {:error, reason}

  @spec record_payment(Subscription.t(), String.t()) ::
          {:ok, Payment.t()} | {:error, Ecto.Changeset.t()}
  defp record_payment(sub, charge_id) do
    %Payment{}
    |> Payment.changeset(%{
      subscription_id: sub.id,
      customer_id: sub.customer_id,
      amount_cents: sub.plan_price_cents,
      provider_charge_id: charge_id,
      status: :captured,
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec advance_cycle(Subscription.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  defp advance_cycle(sub) do
    sub
    |> Subscription.advance_cycle_changeset()
    |> Repo.update()
  end

  @spec mark_past_due(Subscription.t(), term()) :: {:ok, :past_due}
  defp mark_past_due(sub, reason) do
    sub
    |> Subscription.past_due_changeset(%{failure_reason: inspect(reason)})
    |> Repo.update()

    {:ok, :past_due}
  end
end
```
