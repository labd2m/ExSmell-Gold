```elixir
defmodule MyApp.FeatureFlags.FeatureFlagResolver do
  @moduledoc """
  Resolves feature flag states for users and organisations by consulting
  the remote flag configuration service and applying targeting rules.
  """

  require Logger

  alias MyApp.FeatureFlags.{FlagConfigClient, TargetingEngine, AuditLog}
  alias MyApp.Accounts.User

  @cache_ttl_ms 30_000
  @default_flags %{new_dashboard: false, beta_billing: false, advanced_search: false}

  @doc """
  Returns a map of feature flags and their resolved boolean values for
  the given user. Uses a local ETS cache to avoid excessive remote calls.
  """
  @spec for_user(User.t()) :: map()
  def for_user(%User{id: user_id, organisation_id: org_id} = user) do
    cache_key = "flags:user:#{user_id}"

    case :ets.lookup(:flag_cache, cache_key) do
      [{^cache_key, flags, expires_at}] when expires_at > :os.system_time(:millisecond) ->
        flags

      _ ->
        flags = fetch_and_resolve(user, org_id)
        expires_at = :os.system_time(:millisecond) + @cache_ttl_ms
        :ets.insert(:flag_cache, {cache_key, flags, expires_at})
        flags
    end
  end

  @doc """
  Checks whether a single named flag is enabled for a user.
  """
  @spec enabled?(User.t(), atom()) :: boolean()
  def enabled?(%User{} = user, flag_name) when is_atom(flag_name) do
    flags = for_user(user)
    Map.get(flags, flag_name, false)
  end

  defp fetch_and_resolve(%User{} = user, org_id) do
    case FlagConfigClient.fetch_flags(org_id) do
      {:ok, raw_flags} ->
        Logger.debug("Fetched flags from remote", flag_count: length(raw_flags), org_id: org_id)
        resolve_flags(raw_flags, user)

      {:error, reason} ->
        Logger.warning("Failed to fetch feature flags, using defaults", reason: inspect(reason))
        @default_flags
    end
  end

  defp resolve_flags(raw_flags, user) when is_list(raw_flags) do
    raw_flags
    |> Enum.map(fn %{"name" => name, "enabled" => globally_enabled, "targeting" => targeting} ->
      flag_atom = String.to_atom(name)
      effective = globally_enabled && TargetingEngine.matches?(user, targeting)
      {flag_atom, effective}
    end)
    |> Map.new()
  end

  defp resolve_flags(_, _), do: @default_flags

  defp audit_flag_access(user_id, flags) do
    sampled = Enum.take_every(Map.to_list(flags), 5)
    AuditLog.record(:flag_resolution, %{user_id: user_id, flags: sampled, resolved_at: DateTime.utc_now()})
  end
end
```
