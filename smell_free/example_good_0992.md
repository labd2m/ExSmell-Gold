```elixir
defmodule Experiments.AssignmentEngine do
  @moduledoc """
  Assigns users to experiment variants using deterministic, user-stable
  bucketing. The assignment is computed from a hash of the user ID and
  experiment name, ensuring the same user always lands in the same variant
  within a given experiment. Assignment records are persisted so analytics
  can correlate outcomes with cohort membership after the experiment concludes.
  """

  alias Experiments.{Assignment, Experiment, Repo}

  require Logger

  @type user_id :: binary()
  @type experiment_name :: binary()
  @type variant :: binary()

  @doc """
  Returns the variant assigned to `user_id` for `experiment_name`.
  Creates and persists a new assignment if one does not already exist.
  Returns `{:ok, variant}` or `{:error, reason}`.
  """
  @spec assign(user_id(), experiment_name()) ::
          {:ok, variant()} | {:error, :experiment_not_found | :not_eligible | term()}
  def assign(user_id, experiment_name)
      when is_binary(user_id) and is_binary(experiment_name) do
    with {:ok, experiment} <- fetch_active_experiment(experiment_name),
         :ok <- check_eligibility(user_id, experiment) do
      case existing_assignment(user_id, experiment.id) do
        {:ok, assignment} ->
          {:ok, assignment.variant}

        :not_found ->
          variant = compute_variant(user_id, experiment)
          persist_and_return(user_id, experiment, variant)
      end
    end
  end

  @doc """
  Returns `true` when `user_id` is in the `variant` group for `experiment_name`.
  Returns `false` when the experiment does not exist, the user is not eligible,
  or the user is in a different variant.
  """
  @spec in_variant?(user_id(), experiment_name(), variant()) :: boolean()
  def in_variant?(user_id, experiment_name, variant)
      when is_binary(user_id) and is_binary(experiment_name) and is_binary(variant) do
    case assign(user_id, experiment_name) do
      {:ok, ^variant} -> true
      _ -> false
    end
  end

  @doc """
  Returns all current assignments for `user_id` as a map of
  `experiment_name => variant`. Useful for passing experiment context
  to analytics events.
  """
  @spec all_assignments(user_id()) :: %{experiment_name() => variant()}
  def all_assignments(user_id) when is_binary(user_id) do
    Assignment
    |> where([a], a.user_id == ^user_id)
    |> join(:inner, [a], e in Experiment, on: a.experiment_id == e.id and e.status == :active)
    |> select([a, e], {e.name, a.variant})
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_active_experiment(name) do
    case Repo.get_by(Experiment, name: name, status: :active) do
      nil -> {:error, :experiment_not_found}
      experiment -> {:ok, experiment}
    end
  end

  defp check_eligibility(user_id, %Experiment{} = experiment) do
    cond do
      experiment.user_segment == :all ->
        :ok

      experiment.user_segment == :new_users ->
        if is_new_user?(user_id), do: :ok, else: {:error, :not_eligible}

      experiment.user_segment == :premium_users ->
        if is_premium?(user_id), do: :ok, else: {:error, :not_eligible}

      true ->
        :ok
    end
  end

  defp existing_assignment(user_id, experiment_id) do
    case Repo.get_by(Assignment, user_id: user_id, experiment_id: experiment_id) do
      nil -> :not_found
      assignment -> {:ok, assignment}
    end
  end

  defp compute_variant(user_id, %Experiment{variants: variants}) do
    total_weight = Enum.sum_by(variants, & &1.weight)
    bucket = :erlang.phash2({user_id, :variant_seed}, total_weight)

    Enum.reduce_while(variants, bucket, fn variant, remaining ->
      if remaining < variant.weight do
        {:halt, variant.name}
      else
        {:cont, remaining - variant.weight}
      end
    end)
  end

  defp persist_and_return(user_id, experiment, variant) do
    case Repo.insert(Assignment.changeset(%Assignment{}, %{
           user_id: user_id,
           experiment_id: experiment.id,
           variant: variant
         }), on_conflict: :nothing, conflict_target: [:user_id, :experiment_id]) do
      {:ok, _} ->
        Logger.debug("Experiment assignment created",
          user_id: user_id,
          experiment: experiment.name,
          variant: variant
        )

        {:ok, variant}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp is_new_user?(user_id) do
    case MyApp.Accounts.fetch_user(user_id) do
      {:ok, user} -> DateTime.diff(DateTime.utc_now(), user.inserted_at, :day) <= 7
      _ -> false
    end
  end

  defp is_premium?(user_id) do
    case MyApp.Billing.fetch_subscription(user_id) do
      {:ok, %{plan: plan}} -> plan in [:growth, :enterprise]
      _ -> false
    end
  end
end
```
