```elixir
defmodule Platform.AbTesting do
  @moduledoc """
  A deterministic A/B test variant assignment context.

  Variant assignments are computed by hashing `{experiment_id, subject_id}`,
  producing stable, reproducible bucketing without database round-trips.
  Experiment definitions are loaded from the database and cached.
  Manual overrides are supported for QA and internal testing.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.{Repo, AbTesting.Experiment, AbTesting.Override}

  @type subject_id :: pos_integer() | String.t()
  @type experiment_id :: String.t()
  @type variant :: String.t()
  @type assignment :: %{variant: variant(), experiment_id: experiment_id(), reason: :hash | :override | :default}

  @doc """
  Returns the assigned variant for `subject_id` in `experiment_id`.
  Checks manual overrides first, then falls back to hash-based bucketing.
  """
  @spec assign(experiment_id(), subject_id()) :: {:ok, assignment()} | {:error, :experiment_not_found}
  def assign(experiment_id, subject_id) when is_binary(experiment_id) do
    case fetch_experiment(experiment_id) do
      {:ok, experiment} ->
        assignment = resolve_assignment(experiment, subject_id)
        {:ok, assignment}

      {:error, :not_found} ->
        {:error, :experiment_not_found}
    end
  end

  @doc """
  Assigns all active experiments for `subject_id` in a single call.
  Returns a map of `experiment_id => assignment`.
  """
  @spec assign_all(subject_id()) :: %{optional(experiment_id()) => assignment()}
  def assign_all(subject_id) do
    list_active()
    |> Map.new(fn experiment ->
      assignment = resolve_assignment(experiment, subject_id)
      {experiment.id, assignment}
    end)
  end

  @doc "Returns `true` if `subject_id` is in the given variant of `experiment_id`."
  @spec in_variant?(experiment_id(), subject_id(), variant()) :: boolean()
  def in_variant?(experiment_id, subject_id, expected_variant) do
    case assign(experiment_id, subject_id) do
      {:ok, %{variant: ^expected_variant}} -> true
      _ -> false
    end
  end

  @doc "Lists all currently active experiments."
  @spec list_active() :: [Experiment.t()]
  def list_active do
    from(e in Experiment,
      where: e.active == true and e.starts_at <= ^DateTime.utc_now(),
      where: is_nil(e.ends_at) or e.ends_at >= ^DateTime.utc_now()
    )
    |> Repo.all()
  end

  defp fetch_experiment(experiment_id) do
    case Repo.get_by(Experiment, id: experiment_id, active: true) do
      nil -> {:error, :not_found}
      exp -> {:ok, exp}
    end
  end

  defp resolve_assignment(%Experiment{id: exp_id} = experiment, subject_id) do
    case check_override(exp_id, subject_id) do
      {:ok, variant} ->
        %{variant: variant, experiment_id: exp_id, reason: :override}

      :no_override ->
        variant = bucket(exp_id, subject_id, experiment.variants)
        %{variant: variant, experiment_id: exp_id, reason: :hash}
    end
  end

  defp check_override(experiment_id, subject_id) do
    case Repo.get_by(Override, experiment_id: experiment_id, subject_id: to_string(subject_id)) do
      nil -> :no_override
      %Override{variant: variant} -> {:ok, variant}
    end
  end

  defp bucket(experiment_id, subject_id, variants) when is_list(variants) and variants != [] do
    hash = :erlang.phash2({experiment_id, to_string(subject_id)}, 10_000)
    total = Enum.sum(Enum.map(variants, & &1.weight))
    position = rem(hash, total)

    Enum.reduce_while(variants, 0, fn %{name: name, weight: weight}, acc ->
      if position < acc + weight do
        {:halt, name}
      else
        {:cont, acc + weight}
      end
    end)
  end

  defp bucket(_experiment_id, _subject_id, []), do: "control"
end
```
