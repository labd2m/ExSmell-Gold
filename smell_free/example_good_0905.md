```elixir
defmodule Subscriptions.TrialManager do
  @moduledoc """
  Manages free-trial lifecycles for subscription accounts. A trial is
  created with a fixed duration, transitions to expired when time runs out,
  and can be converted to a paid subscription at any point during its
  window. The manager enforces that each account receives at most one trial
  per plan and persists all state through Ecto for auditability.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Subscriptions.{Trial, Subscription}

  @type account_id :: String.t()
  @type plan_id :: String.t()
  @type trial_id :: Ecto.UUID.t()

  @default_trial_days 14

  @doc """
  Starts a trial for `account_id` on `plan_id`. Returns
  `{:error, :already_trialled}` when a trial for this plan already exists.
  """
  @spec start(account_id(), plan_id(), pos_integer()) ::
          {:ok, Trial.t()} | {:error, :already_trialled | Ecto.Changeset.t()}
  def start(account_id, plan_id, trial_days \\\\ @default_trial_days)
      when is_binary(account_id) and is_binary(plan_id)
      and is_integer(trial_days) and trial_days > 0 do
    if previous_trial_exists?(account_id, plan_id) do
      {:error, :already_trialled}
    else
      expires_at = DateTime.add(DateTime.utc_now(), trial_days * 86_400, :second)
      attrs = %{account_id: account_id, plan_id: plan_id, status: "active", expires_at: expires_at}
      %Trial{} |> Trial.changeset(attrs) |> Repo.insert()
    end
  end

  @doc """
  Converts an active trial to a paid subscription. The trial is marked
  converted and a new Subscription record is created atomically.
  """
  @spec convert(trial_id(), map()) ::
          {:ok, Subscription.t()} | {:error, :trial_not_active | :trial_not_found | Ecto.Changeset.t()}
  def convert(trial_id, subscription_params) when is_binary(trial_id) and is_map(subscription_params) do
    case Repo.get(Trial, trial_id) do
      nil ->
        {:error, :trial_not_found}

      %Trial{status: status} when status != "active" ->
        {:error, :trial_not_active}

      %Trial{} = trial ->
        Repo.transaction(fn ->
          trial |> Trial.status_changeset("converted") |> Repo.update!()

          attrs = Map.merge(subscription_params, %{account_id: trial.account_id, plan_id: trial.plan_id})

          case %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert() do
            {:ok, sub} -> sub
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  @doc """
  Expires all trials whose `expires_at` has passed and whose status
  is still active. Returns the count of expired trials.
  """
  @spec expire_overdue() :: {:ok, non_neg_integer()}
  def expire_overdue do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(t in Trial, where: t.status == "active" and t.expires_at < ^now),
        set: [status: "expired", updated_at: now]
      )

    {:ok, count}
  end

  @doc "Returns the active trial for `account_id` and `plan_id`, if any."
  @spec active_trial(account_id(), plan_id()) :: {:ok, Trial.t()} | {:error, :none}
  def active_trial(account_id, plan_id) when is_binary(account_id) and is_binary(plan_id) do
    now = DateTime.utc_now()

    result =
      Repo.one(
        from(t in Trial,
          where: t.account_id == ^account_id and t.plan_id == ^plan_id
                 and t.status == "active" and t.expires_at > ^now
        )
      )

    case result do
      nil -> {:error, :none}
      trial -> {:ok, trial}
    end
  end

  @doc "Returns remaining trial days for an active trial, or 0 if expired."
  @spec days_remaining(Trial.t()) :: non_neg_integer()
  def days_remaining(%Trial{expires_at: exp}) do
    max(0, DateTime.diff(exp, DateTime.utc_now(), :second) |> div(86_400))
  end

  defp previous_trial_exists?(account_id, plan_id) do
    Repo.exists?(from(t in Trial, where: t.account_id == ^account_id and t.plan_id == ^plan_id))
  end
end
```
