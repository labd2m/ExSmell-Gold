```elixir
defmodule Subscriptions.StateMachine do
  @moduledoc """
  Pure functional state machine for subscription lifecycle transitions.
  Each transition is an explicit function that validates the current state,
  applies the change, and returns the updated struct. No side effects are
  performed here; persistence and event emission are the caller's responsibility.
  """

  alias Subscriptions.Subscription

  @type transition_error ::
          :invalid_transition
          | :already_cancelled
          | :not_active
          | :trial_already_converted
          | :grace_period_expired

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Activates a subscription that is currently in `:trialing` or `:pending` status.
  Returns `{:ok, updated}` or `{:error, reason}`.
  """
  @spec activate(Subscription.t()) :: {:ok, Subscription.t()} | {:error, transition_error()}
  def activate(%Subscription{status: status} = sub) when status in [:trialing, :pending] do
    {:ok, %Subscription{sub | status: :active, activated_at: utc_now()}}
  end

  def activate(%Subscription{status: :active}), do: {:error, :invalid_transition}
  def activate(%Subscription{}), do: {:error, :invalid_transition}

  @doc """
  Converts a trialing subscription to an active paid subscription.
  """
  @spec convert_trial(Subscription.t()) :: {:ok, Subscription.t()} | {:error, transition_error()}
  def convert_trial(%Subscription{status: :trialing} = sub) do
    {:ok, %Subscription{sub | status: :active, trial_converted_at: utc_now()}}
  end

  def convert_trial(%Subscription{status: :active}), do: {:error, :trial_already_converted}
  def convert_trial(%Subscription{}), do: {:error, :invalid_transition}

  @doc """
  Places an active subscription into a grace period when payment fails.
  Grace period subscriptions remain accessible but are flagged for collection.
  """
  @spec enter_grace_period(Subscription.t(), Date.t()) ::
          {:ok, Subscription.t()} | {:error, transition_error()}
  def enter_grace_period(%Subscription{status: :active} = sub, grace_until) when is_struct(grace_until, Date) do
    {:ok, %Subscription{sub | status: :grace_period, grace_until: grace_until}}
  end

  def enter_grace_period(%Subscription{}), do: {:error, :not_active}

  @doc """
  Suspends a subscription that is in grace period after the deadline passes.
  """
  @spec suspend(Subscription.t()) :: {:ok, Subscription.t()} | {:error, transition_error()}
  def suspend(%Subscription{status: :grace_period} = sub) do
    if Date.compare(Date.utc_today(), sub.grace_until) == :gt do
      {:ok, %Subscription{sub | status: :suspended, suspended_at: utc_now()}}
    else
      {:error, :grace_period_expired}
    end
  end

  def suspend(%Subscription{}), do: {:error, :invalid_transition}

  @doc """
  Cancels any non-cancelled subscription, recording the cancellation reason.
  """
  @spec cancel(Subscription.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, transition_error()}
  def cancel(%Subscription{status: :cancelled}, _reason), do: {:error, :already_cancelled}

  def cancel(%Subscription{} = sub, reason) when is_binary(reason) do
    {:ok,
     %Subscription{
       sub
       | status: :cancelled,
         cancelled_at: utc_now(),
         cancellation_reason: reason
     }}
  end

  @doc """
  Reactivates a suspended or cancelled subscription.
  """
  @spec reactivate(Subscription.t()) :: {:ok, Subscription.t()} | {:error, transition_error()}
  def reactivate(%Subscription{status: status} = sub) when status in [:suspended, :cancelled] do
    {:ok, %Subscription{sub | status: :active, reactivated_at: utc_now(), grace_until: nil}}
  end

  def reactivate(%Subscription{}), do: {:error, :invalid_transition}

  @doc """
  Returns the set of valid next statuses reachable from the given status.
  Useful for generating transition options in admin UI.
  """
  @spec reachable_statuses(Subscription.status()) :: [Subscription.status()]
  def reachable_statuses(:pending), do: [:active]
  def reachable_statuses(:trialing), do: [:active, :cancelled]
  def reachable_statuses(:active), do: [:grace_period, :cancelled]
  def reachable_statuses(:grace_period), do: [:active, :suspended, :cancelled]
  def reachable_statuses(:suspended), do: [:active, :cancelled]
  def reachable_statuses(:cancelled), do: [:active]

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp utc_now, do: DateTime.utc_now()
end
```
