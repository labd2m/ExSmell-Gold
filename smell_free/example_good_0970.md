```elixir
defmodule MyApp.Platform.FeatureRollout do
  @moduledoc """
  Manages graduated feature rollouts using ring-based cohort assignment.
  A rollout progresses through named rings (canary → early_access →
  general → full), each covering a larger percentage of users. Users
  are assigned to rings deterministically by hashing their ID, so the
  same user always falls in the same ring for a given rollout.

  Rollout configurations are stored in the `feature_rollouts` table and
  cached briefly in ETS for high read throughput.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Platform.FeatureRolloutConfig

  @cache_ttl_ms 30_000
  @rings [:canary, :early_access, :general, :full]

  @ring_percentages %{
    canary: 1,
    early_access: 10,
    general: 50,
    full: 100
  }

  @type feature_name :: String.t()
  @type user_id :: String.t()
  @type ring :: :canary | :early_access | :general | :full

  @doc """
  Returns `true` when `user_id` is within the active rollout ring for
  `feature_name`. Returns `false` when the feature is disabled or the
  user falls outside the current ring percentage.
  """
  @spec enabled_for?(feature_name(), user_id()) :: boolean()
  def enabled_for?(feature_name, user_id)
      when is_binary(feature_name) and is_binary(user_id) do
    case fetch_config(feature_name) do
      nil -> false
      %{active: false} -> false
      config -> user_in_ring?(user_id, feature_name, config.current_ring)
    end
  end

  @doc "Returns the active ring name for `feature_name`, or `nil` if disabled."
  @spec current_ring(feature_name()) :: ring() | nil
  def current_ring(feature_name) when is_binary(feature_name) do
    case fetch_config(feature_name) do
      nil -> nil
      %{active: false} -> nil
      config -> config.current_ring
    end
  end

  @doc """
  Advances `feature_name` to the next ring. Returns `{:error, :already_full}`
  when already at full rollout.
  """
  @spec advance(feature_name()) ::
          {:ok, ring()} | {:error, :feature_not_found} | {:error, :already_full}
  def advance(feature_name) when is_binary(feature_name) do
    case Repo.get_by(FeatureRolloutConfig, name: feature_name) do
      nil ->
        {:error, :feature_not_found}

      %{current_ring: :full} ->
        {:error, :already_full}

      config ->
        next = next_ring(config.current_ring)

        config
        |> FeatureRolloutConfig.changeset(%{current_ring: next})
        |> Repo.update()

        MyApp.Cache.delete({:feature_rollout, feature_name})
        {:ok, next}
    end
  end

  @spec user_in_ring?(user_id(), feature_name(), ring()) :: boolean()
  defp user_in_ring?(user_id, feature_name, ring) do
    bucket = hash_bucket(user_id, feature_name)
    threshold = Map.fetch!(@ring_percentages, ring)
    bucket < threshold
  end

  @spec hash_bucket(user_id(), feature_name()) :: non_neg_integer()
  defp hash_bucket(user_id, feature_name) do
    seed = "#{feature_name}:#{user_id}"

    :crypto.hash(:sha256, seed)
    |> binary_part(0, 4)
    |> :binary.decode_unsigned()
    |> rem(100)
  end

  @spec next_ring(ring()) :: ring()
  defp next_ring(current) do
    idx = Enum.find_index(@rings, &(&1 == current))
    Enum.at(@rings, min(idx + 1, length(@rings) - 1))
  end

  @spec fetch_config(feature_name()) :: FeatureRolloutConfig.t() | nil
  defp fetch_config(feature_name) do
    cache_key = {:feature_rollout, feature_name}

    case MyApp.Cache.fetch_or_store(cache_key, fn ->
           Repo.get_by(FeatureRolloutConfig, name: feature_name)
         end, @cache_ttl_ms) do
      {:ok, config} -> config
    end
  end
end
```
