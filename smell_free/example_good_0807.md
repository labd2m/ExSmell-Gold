```elixir
defmodule MyApp.Subscriptions.TrialManager do
  @moduledoc """
  Manages free trial lifecycles: starting trials, checking expiry, and
  converting or expiring them. Trial state is persisted in the
  `subscription_trials` table; no in-process state is required. Expiry
  checks run from a nightly Oban job that calls `expire_overdue/0`.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Subscriptions.{Trial, Subscription}
  alias MyApp.Billing
  alias MyApp.Notifications.Dispatcher

  @default_trial_days 14
  @expiry_warning_days 3

  @type user_id :: String.t()
  @type plan_slug :: String.t()

  @doc """
  Starts a free trial for `user_id` on `plan_slug`. Returns
  `{:error, :already_trialled}` when the user has previously had a trial
  on this plan.
  """
  @spec start(user_id(), plan_slug(), pos_integer()) ::
          {:ok, Trial.t()} | {:error, :already_trialled} | {:error, Ecto.Changeset.t()}
  def start(user_id, plan_slug, trial_days \\ @default_trial_days)
      when is_binary(user_id) and is_binary(plan_slug) do
    if previously_trialled?(user_id, plan_slug) do
      {:error, :already_trialled}
    else
      ends_at = DateTime.add(DateTime.utc_now(), trial_days, :day)

      %Trial{}
      |> Trial.changeset(%{
        user_id: user_id,
        plan_slug: plan_slug,
        ends_at: ends_at,
        status: :active
      })
      |> Repo.insert()
    end
  end

  @doc "Returns the active trial for `user_id`, or `nil`."
  @spec active_trial(user_id()) :: Trial.t() | nil
  def active_trial(user_id) when is_binary(user_id) do
    Trial
    |> where([t], t.user_id == ^user_id and t.status == :active)
    |> where([t], t.ends_at > ^DateTime.utc_now())
    |> Repo.one()
  end

  @doc "Returns the number of days remaining in `trial`."
  @spec days_remaining(Trial.t()) :: non_neg_integer()
  def days_remaining(%Trial{ends_at: ends_at}) do
    max(DateTime.diff(ends_at, DateTime.utc_now(), :day), 0)
  end

  @doc """
  Converts `trial` to a paid subscription on `plan_slug` using
  `payment_method_id`. Marks the trial as `:converted`.
  """
  @spec convert(Trial.t(), plan_slug(), String.t()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def convert(%Trial{} = trial, plan_slug, payment_method_id) do
    with {:ok, subscription} <- Billing.subscribe(trial.user_id, plan_slug, payment_method_id) do
      trial
      |> Trial.changeset(%{status: :converted, converted_at: DateTime.utc_now()})
      |> Repo.update()

      {:ok, subscription}
    end
  end

  @doc """
  Expires all trials whose end date has passed and sends expiry
  notifications. Returns the count of expired trials.
  """
  @spec expire_overdue() :: non_neg_integer()
  def expire_overdue do
    now = DateTime.utc_now()

    overdue =
      Trial
      |> where([t], t.status == :active and t.ends_at <= ^now)
      |> Repo.all()

    Enum.each(overdue, &expire_trial/1)
    length(overdue)
  end

  @doc "Sends a warning notification to users whose trial expires within 3 days."
  @spec send_expiry_warnings() :: non_neg_integer()
  def send_expiry_warnings do
    cutoff = DateTime.add(DateTime.utc_now(), @expiry_warning_days, :day)

    soon_expiring =
      Trial
      |> where([t], t.status == :active and t.ends_at <= ^cutoff and t.ends_at > ^DateTime.utc_now())
      |> where([t], t.warning_sent == false)
      |> Repo.all()

    Enum.each(soon_expiring, &send_warning/1)
    length(soon_expiring)
  end

  @spec previously_trialled?(user_id(), plan_slug()) :: boolean()
  defp previously_trialled?(user_id, plan_slug) do
    Trial
    |> where([t], t.user_id == ^user_id and t.plan_slug == ^plan_slug)
    |> Repo.exists?()
  end

  @spec expire_trial(Trial.t()) :: :ok
  defp expire_trial(trial) do
    trial
    |> Trial.changeset(%{status: :expired, expired_at: DateTime.utc_now()})
    |> Repo.update()

    Dispatcher.dispatch(%{
      channels: [:email],
      recipient_email: trial.user_email,
      subject: "Your free trial has ended",
      body: "Your #{trial.plan_slug} trial has expired. Upgrade to continue.",
      id: "trial_expired_#{trial.id}"
    })

    :ok
  end

  @spec send_warning(Trial.t()) :: :ok
  defp send_warning(trial) do
    days = days_remaining(trial)

    Dispatcher.dispatch(%{
      channels: [:email],
      recipient_email: trial.user_email,
      subject: "Your trial expires in #{days} day(s)",
      body: "Your #{trial.plan_slug} trial ends in #{days} day(s).",
      id: "trial_warning_#{trial.id}"
    })

    trial
    |> Trial.changeset(%{warning_sent: true})
    |> Repo.update()

    :ok
  end
end
```
