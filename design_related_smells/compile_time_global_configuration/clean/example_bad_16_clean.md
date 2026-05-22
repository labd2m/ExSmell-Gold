```elixir
defmodule FeatureFlags.Registry do
  @moduledoc """
  Central registry for evaluating feature flags. Flags are configured
  statically per environment and checked throughout the application to
  gate experimental or rolling features. This module is intended to be
  used as a library dependency by other applications.
  """

  require Logger

  @enabled_features Application.fetch_env!(:feature_flags, :enabled_features)

  @known_features ~w(
    new_checkout_flow
    ai_recommendations
    dark_mode
    multi_currency
    bulk_export
    advanced_search
    beta_dashboard
    realtime_notifications
  )a

  @type feature :: atom()

  @doc """
  Returns `true` if `feature` is currently enabled; `false` otherwise.

  Logs a warning if `feature` is not in the known-features registry.

  ## Examples

      iex> FeatureFlags.Registry.enabled?(:dark_mode)
      true
  """
  @spec enabled?(feature()) :: boolean()
  def enabled?(feature) when is_atom(feature) do
    unless feature in @known_features do
      Logger.warning("Unknown feature flag queried feature=#{feature}")
    end

    feature in @enabled_features
  end

  @doc """
  Returns the list of all currently enabled features.
  """
  @spec list_enabled() :: [feature()]
  def list_enabled, do: @enabled_features

  @doc """
  Returns the list of all known feature flags, regardless of whether they
  are currently enabled.
  """
  @spec list_known() :: [feature()]
  def list_known, do: @known_features

  @doc """
  Raises `FeatureFlags.DisabledError` if `feature` is not enabled. Useful
  for guarding controller actions or service calls at the boundary level.

  ## Parameters
    - `feature` - The atom identifying the feature to assert.

  ## Examples

      iex> FeatureFlags.Registry.assert_enabled!(:bulk_export)
      :ok  # if enabled

      iex> FeatureFlags.Registry.assert_enabled!(:bulk_export)
      ** (FeatureFlags.DisabledError) Feature :bulk_export is not enabled  # if disabled
  """
  @spec assert_enabled!(feature()) :: :ok
  def assert_enabled!(feature) when is_atom(feature) do
    if enabled?(feature) do
      :ok
    else
      raise FeatureFlags.DisabledError, feature: feature
    end
  end

  @doc """
  Returns a map of every known flag with its current enabled status.
  Useful for diagnostics endpoints or admin dashboards.

  ## Examples

      iex> FeatureFlags.Registry.status_map()
      %{dark_mode: true, new_checkout_flow: false, ...}
  """
  @spec status_map() :: %{feature() => boolean()}
  def status_map do
    Map.new(@known_features, fn f -> {f, enabled?(f)} end)
  end

  @doc """
  Returns `true` if every feature in `features` is enabled.
  Useful when a code path requires multiple flags simultaneously.
  """
  @spec all_enabled?([feature()]) :: boolean()
  def all_enabled?(features) when is_list(features) do
    Enum.all?(features, &enabled?/1)
  end

  @doc """
  Returns `true` if at least one feature in `features` is enabled.
  """
  @spec any_enabled?([feature()]) :: boolean()
  def any_enabled?(features) when is_list(features) do
    Enum.any?(features, &enabled?/1)
  end
end
```
