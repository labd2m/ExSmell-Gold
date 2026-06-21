```elixir
defmodule Platform.FeatureFlags do
  @moduledoc """
  Manages feature flags stored in PostgreSQL with an in-process ETS cache
  for low-latency reads. Flags can be enabled globally, for specific tenants,
  or for a percentage rollout. The cache is invalidated via PubSub whenever
  a flag is modified so all nodes in the cluster converge without a restart.
  """

  alias Platform.{FeatureFlag, Repo}
  alias Ecto.Multi
  import Ecto.Query

  require Logger

  @table :feature_flags_cache
  @pubsub_topic "feature_flags:invalidation"

  # ---------------------------------------------------------------------------
  # Cache management
  # ---------------------------------------------------------------------------

  @doc """
  Initialises the ETS cache and subscribes to flag invalidation events.
  Call once from a supervised `GenServer` or `Application.start/2`.
  """
  @spec init_cache() :: :ok
  def init_cache do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(Platform.PubSub, @pubsub_topic)
    warm_cache()
  end

  # ---------------------------------------------------------------------------
  # Flag evaluation
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the flag identified by `flag_key` is enabled for
  the given `context`. Context may include `:tenant_id` and `:user_id`.
  Falls back to the global setting when no tenant override is found.
  """
  @spec enabled?(binary(), map()) :: boolean()
  def enabled?(flag_key, context \\ %{}) when is_binary(flag_key) do
    case lookup_cache(flag_key) do
      {:ok, flag} -> evaluate(flag, context)
      :miss -> fetch_and_evaluate(flag_key, context)
    end
  end

  # ---------------------------------------------------------------------------
  # Flag management
  # ---------------------------------------------------------------------------

  @doc """
  Creates or updates a feature flag configuration.
  Broadcasts a cache invalidation to all cluster nodes after a successful write.
  """
  @spec upsert(binary(), map()) :: {:ok, FeatureFlag.t()} | {:error, term()}
  def upsert(flag_key, attrs) when is_binary(flag_key) and is_map(attrs) do
    Multi.new()
    |> Multi.insert_or_update(:flag, build_upsert_changeset(flag_key, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{flag: flag}} ->
        invalidate_cache(flag_key)
        {:ok, flag}

      {:error, :flag, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists all feature flags ordered alphabetically by key.
  """
  @spec list_all() :: [FeatureFlag.t()]
  def list_all do
    FeatureFlag
    |> order_by([f], asc: f.key)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp evaluate(%FeatureFlag{enabled: false}, _context), do: false
  defp evaluate(%FeatureFlag{enabled: true, rollout_percent: 100}, _context), do: true

  defp evaluate(%FeatureFlag{tenant_overrides: overrides} = flag, %{tenant_id: tenant_id})
       when is_binary(tenant_id) do
    case Map.get(overrides, tenant_id) do
      true -> true
      false -> false
      nil -> evaluate_rollout(flag, tenant_id)
    end
  end

  defp evaluate(%FeatureFlag{} = flag, context) do
    bucket_key = Map.get(context, :user_id, Map.get(context, :tenant_id, ""))
    evaluate_rollout(flag, bucket_key)
  end

  defp evaluate_rollout(%FeatureFlag{rollout_percent: pct}, bucket_key) when pct > 0 do
    bucket = :erlang.phash2(bucket_key, 100) + 1
    bucket <= pct
  end

  defp evaluate_rollout(_flag, _key), do: false

  defp lookup_cache(flag_key) do
    case :ets.lookup(@table, flag_key) do
      [{^flag_key, flag}] -> {:ok, flag}
      [] -> :miss
    end
  end

  defp fetch_and_evaluate(flag_key, context) do
    case Repo.get_by(FeatureFlag, key: flag_key) do
      nil ->
        false

      flag ->
        :ets.insert(@table, {flag_key, flag})
        evaluate(flag, context)
    end
  end

  defp invalidate_cache(flag_key) do
    :ets.delete(@table, flag_key)
    Phoenix.PubSub.broadcast(Platform.PubSub, @pubsub_topic, {:invalidate, flag_key})
  end

  defp warm_cache do
    Repo.all(FeatureFlag)
    |> Enum.each(fn flag -> :ets.insert(@table, {flag.key, flag}) end)

    Logger.info("FeatureFlags cache warmed with #{:ets.info(@table, :size)} flags")
    :ok
  end

  defp build_upsert_changeset(flag_key, attrs) do
    existing = Repo.get_by(FeatureFlag, key: flag_key) || %FeatureFlag{}
    FeatureFlag.changeset(existing, Map.put(attrs, :key, flag_key))
  end
end
```
