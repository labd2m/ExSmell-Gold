```elixir
defmodule Platform.FeatureFlags do
  @moduledoc """
  A stateless feature flag evaluator that resolves flag states for a given
  actor context.

  Flag rules are stored in the database and cached via the application's
  cache layer. Evaluation is pure: flags are either globally enabled,
  enabled for specific accounts, or enabled by a percentage rollout.
  """

  alias Platform.FeatureFlags.{Rule, Store}

  @type actor :: %{id: pos_integer(), plan: atom(), metadata: map()}
  @type flag_name :: atom()
  @type evaluation :: :enabled | :disabled

  @doc """
  Returns `:enabled` if the flag is active for `actor`, `:disabled` otherwise.
  """
  @spec evaluate(flag_name(), actor()) :: evaluation()
  def evaluate(flag_name, %{id: _} = actor) when is_atom(flag_name) do
    case Store.fetch(flag_name) do
      {:ok, rule} -> apply_rule(rule, actor)
      {:error, :not_found} -> :disabled
    end
  end

  @doc """
  Returns `true` if the flag is enabled for `actor`.
  Convenience wrapper around `evaluate/2`.
  """
  @spec enabled?(flag_name(), actor()) :: boolean()
  def enabled?(flag_name, actor), do: evaluate(flag_name, actor) == :enabled

  @doc """
  Evaluates multiple flags at once. Returns a map of `flag_name => evaluation`.
  """
  @spec evaluate_all([flag_name()], actor()) :: %{optional(flag_name()) => evaluation()}
  def evaluate_all(flag_names, actor) when is_list(flag_names) do
    Map.new(flag_names, fn flag -> {flag, evaluate(flag, actor)} end)
  end

  defp apply_rule(%Rule{state: :disabled}, _actor), do: :disabled
  defp apply_rule(%Rule{state: :enabled}, _actor), do: :enabled

  defp apply_rule(%Rule{state: :allowlist, allowed_account_ids: ids}, %{id: actor_id}) do
    if actor_id in ids, do: :enabled, else: :disabled
  end

  defp apply_rule(%Rule{state: :plan_gate, allowed_plans: plans}, %{plan: plan}) do
    if plan in plans, do: :enabled, else: :disabled
  end

  defp apply_rule(%Rule{state: :percentage_rollout, percentage: pct}, %{id: actor_id}) do
    bucket = :erlang.phash2(actor_id, 100)
    if bucket < pct, do: :enabled, else: :disabled
  end

  defp apply_rule(_rule, _actor), do: :disabled
end

defmodule Platform.FeatureFlags.Rule do
  @moduledoc "Struct representing a feature flag rule loaded from the store."

  @type state ::
          :enabled
          | :disabled
          | :allowlist
          | :plan_gate
          | :percentage_rollout

  @type t :: %__MODULE__{
          name: atom(),
          state: state(),
          allowed_account_ids: [pos_integer()],
          allowed_plans: [atom()],
          percentage: non_neg_integer()
        }

  defstruct [:name, :state, allowed_account_ids: [], allowed_plans: [], percentage: 0]
end

defmodule Platform.FeatureFlags.Store do
  @moduledoc "Loads and caches feature flag rules."

  alias Platform.FeatureFlags.Rule
  alias Platform.{Repo, FeatureFlag}

  @cache_ttl_ms 30_000

  @doc "Fetches a rule by flag name, returning a cached result when available."
  @spec fetch(atom()) :: {:ok, Rule.t()} | {:error, :not_found}
  def fetch(flag_name) when is_atom(flag_name) do
    cache_key = {:feature_flag, flag_name}

    case Platform.Cache.fetch(cache_key) do
      {:ok, rule} ->
        {:ok, rule}

      {:error, _} ->
        load_and_cache(flag_name, cache_key)
    end
  end

  defp load_and_cache(flag_name, cache_key) do
    case Repo.get_by(FeatureFlag, name: Atom.to_string(flag_name)) do
      nil ->
        {:error, :not_found}

      record ->
        rule = to_rule(record)
        Platform.Cache.put(cache_key, rule, @cache_ttl_ms)
        {:ok, rule}
    end
  end

  defp to_rule(record) do
    %Rule{
      name: String.to_existing_atom(record.name),
      state: record.state,
      allowed_account_ids: record.allowed_account_ids || [],
      allowed_plans: record.allowed_plans || [],
      percentage: record.percentage || 0
    }
  end
end
```
