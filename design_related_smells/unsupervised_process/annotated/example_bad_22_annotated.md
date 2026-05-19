# Annotated Example 22 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Subscriptions.RenewalWorker.start/1`
- **Affected function(s):** `start/1`
- **Short explanation:** Each subscription due for renewal gets its own long-running GenServer spawned via `GenServer.start/3` outside any supervision tree. A crash mid-renewal leaves the subscription in an indeterminate state — payment may or may not have been attempted — with no automatic recovery.

```elixir
defmodule Subscriptions.RenewalWorker do
  use GenServer

  @moduledoc """
  Manages the renewal lifecycle for a single subscription.
  Handles retry scheduling with exponential backoff on payment failure,
  dunning notifications, and grace-period enforcement before suspension.
  """

  @max_retry_attempts 4
  @retry_base_delay_hours 6
  @grace_period_days 3

  defstruct [
    :subscription_id,
    :customer_id,
    :plan,
    :amount_cents,
    :currency,
    :renewal_due_at,
    :status,
    :attempt_count,
    :last_attempt_at,
    :last_failure_reason,
    :grace_expires_at,
    :dunning_step
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` spawns a billing-critical
  # renewal worker outside any supervision tree. A SaaS platform can have thousands of
  # subscriptions renewing simultaneously, each with its own unsupervised process.
  # If one crashes between the payment attempt and the status update (e.g., due to an
  # unexpected response shape from the payment provider), the subscription may be
  # charged but never marked as renewed, or the retry timer is lost entirely. No
  # supervisor restarts the process, so the customer is silently left in limbo.
  def start(subscription) do
    state = %__MODULE__{
      subscription_id: subscription.id,
      customer_id: subscription.customer_id,
      plan: subscription.plan,
      amount_cents: subscription.amount_cents,
      currency: subscription.currency,
      renewal_due_at: subscription.renewal_due_at,
      status: :pending,
      attempt_count: 0,
      last_attempt_at: nil,
      last_failure_reason: nil,
      grace_expires_at: nil,
      dunning_step: 0
    }

    GenServer.start(__MODULE__, state, name: via_name(subscription.id))
  end
  # VALIDATION: SMELL END

  @doc "Returns the current renewal status for the subscription."
  def status(subscription_id) do
    GenServer.call(via_name(subscription_id), :status)
  end

  @doc "Manually triggers a retry attempt (e.g., after customer updates payment method)."
  def retry_now(subscription_id) do
    GenServer.cast(via_name(subscription_id), :attempt)
  end

  @doc "Cancels the renewal process (e.g., customer cancelled before renewal)."
  def cancel(subscription_id) do
    GenServer.cast(via_name(subscription_id), :cancel)
  end

  ## Callbacks

  @impl true
  def init(state) do
    delay = max(DateTime.diff(state.renewal_due_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), :attempt, delay)
    {:ok, state}
  end

  @impl true
  def handle_info(:attempt, %{status: :cancelled} = state), do: {:noreply, state}

  def handle_info(:attempt, state) do
    new_state = do_attempt(state)
    {:noreply, new_state}
  end

  def handle_info(:grace_period_expired, state) do
    if state.status == :in_grace_period do
      final = %{state | status: :suspended}
      persist_status_change(final)
      notify_suspension(final)
      {:noreply, final}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:attempt, state) do
    {:noreply, do_attempt(state)}
  end

  def handle_cast(:cancel, state) do
    {:noreply, %{state | status: :cancelled}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    summary = %{
      subscription_id: state.subscription_id,
      status: state.status,
      attempt_count: state.attempt_count,
      last_attempt_at: state.last_attempt_at,
      last_failure_reason: state.last_failure_reason,
      grace_expires_at: state.grace_expires_at,
      dunning_step: state.dunning_step
    }

    {:reply, summary, state}
  end

  defp do_attempt(state) do
    updated = %{
      state
      | attempt_count: state.attempt_count + 1,
        last_attempt_at: DateTime.utc_now(),
        status: :attempting
    }

    case charge_payment(updated) do
      {:ok, _charge_id} ->
        success = %{updated | status: :renewed}
        persist_status_change(success)
        notify_renewal_success(success)
        success

      {:error, reason} ->
        failed = %{updated | last_failure_reason: reason}
        handle_failure(failed)
    end
  end

  defp handle_failure(%{attempt_count: n} = state) when n >= @max_retry_attempts do
    if state.grace_expires_at == nil do
      grace_expires = DateTime.add(DateTime.utc_now(), @grace_period_days, :day)
      grace_ms = DateTime.diff(grace_expires, DateTime.utc_now(), :millisecond)

      Process.send_after(self(), :grace_period_expired, grace_ms)
      send_dunning_notice(state, :grace_period_started)

      %{state | status: :in_grace_period, grace_expires_at: grace_expires}
    else
      state
    end
  end

  defp handle_failure(state) do
    delay_hours = @retry_base_delay_hours * :math.pow(2, state.attempt_count - 1) |> round()
    delay_ms = delay_hours * 3_600_000

    Process.send_after(self(), :attempt, delay_ms)
    send_dunning_notice(state, :payment_failed)

    %{state | status: :retrying, dunning_step: state.dunning_step + 1}
  end

  defp charge_payment(_state), do: {:ok, "ch_simulated"}
  defp persist_status_change(_state), do: :ok
  defp notify_renewal_success(_state), do: :ok
  defp notify_suspension(_state), do: :ok
  defp send_dunning_notice(_state, _event), do: :ok

  defp via_name(subscription_id) do
    {:via, Registry, {Subscriptions.RenewalRegistry, subscription_id}}
  end
end
```
