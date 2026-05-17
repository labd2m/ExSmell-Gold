# Annotated Example 47 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule FeatureFlags.Toggle` declarations
- **Affected functions:** `FeatureFlags.Toggle.enabled?/2`, `FeatureFlags.Toggle.enable/2`, `FeatureFlags.Toggle.disable/2`, `FeatureFlags.Toggle.rollout_percentage/2`, `FeatureFlags.Toggle.all_flags/0`
- **Short explanation:** Two separate source files both declare `defmodule FeatureFlags.Toggle`. BEAM silently discards one definition at load time. Losing feature flag evaluation functions (`enabled?/2`) means every flag check silently fails or crashes, potentially enabling unreleased features for all users or disabling critical functionality without warning.

---

```elixir
# ── file: lib/feature_flags/toggle.ex ───────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `FeatureFlags.Toggle` is declared here
# and again in a second block below. BEAM will drop one definition, silently
# breaking flag evaluation across every feature gate in the application.

defmodule FeatureFlags.Toggle do
  @moduledoc """
  Runtime feature flag evaluation and management.
  Supports per-user targeting, percentage rollouts, and kill switches.
  Defined in `lib/feature_flags/toggle.ex`.
  """

  alias FeatureFlags.{FlagStore, RolloutEngine, OverrideStore, AuditLog}

  @type flag_name :: atom() | String.t()
  @type context :: %{
    optional(:user_id) => String.t(),
    optional(:account_id) => String.t(),
    optional(:env) => String.t(),
    optional(:region) => String.t()
  }

  @doc """
  Evaluate whether a feature flag is enabled for the given context.
  Checks overrides first, then rollout rules, then the global default.
  """
  @spec enabled?(flag_name(), context()) :: boolean()
  def enabled?(flag_name, context \\ %{}) do
    fname = normalise(flag_name)

    with {:ok, flag} <- FlagStore.fetch(fname) do
      cond do
        flag.killed? ->
          false

        override = OverrideStore.get(fname, context) ->
          override.value

        flag.rollout_pct == 100 ->
          true

        flag.rollout_pct == 0 ->
          false

        true ->
          RolloutEngine.evaluate(fname, context, flag.rollout_pct)
      end
    else
      :not_found -> false
    end
  end

  @doc "Enable a flag globally (100% rollout)."
  @spec enable(flag_name(), String.t()) :: :ok | {:error, String.t()}
  def enable(flag_name, actor) do
    fname = normalise(flag_name)

    with {:ok, flag} <- FlagStore.fetch(fname),
         :ok <- FlagStore.update(fname, %{rollout_pct: 100, killed?: false}) do
      AuditLog.record(:flag_enabled, %{flag: fname, actor: actor, prev: flag.rollout_pct})
    else
      :not_found -> {:error, "Unknown flag: #{fname}"}
    end
  end

  @doc "Disable a flag globally (kill switch — 0% rollout)."
  @spec disable(flag_name(), String.t()) :: :ok | {:error, String.t()}
  def disable(flag_name, actor) do
    fname = normalise(flag_name)

    with {:ok, flag} <- FlagStore.fetch(fname),
         :ok <- FlagStore.update(fname, %{killed?: true, rollout_pct: 0}) do
      AuditLog.record(:flag_disabled, %{flag: fname, actor: actor, prev: flag.rollout_pct})
    else
      :not_found -> {:error, "Unknown flag: #{fname}"}
    end
  end

  @doc "Set the percentage of users for whom this flag is enabled."
  @spec rollout_percentage(flag_name(), 0..100) :: :ok | {:error, String.t()}
  def rollout_percentage(flag_name, pct) when pct in 0..100 do
    fname = normalise(flag_name)

    case FlagStore.update(fname, %{rollout_pct: pct, killed?: pct == 0}) do
      :ok -> :ok
      :not_found -> {:error, "Unknown flag: #{fname}"}
    end
  end

  def rollout_percentage(_flag, pct) do
    {:error, "Percentage must be between 0 and 100, got: #{pct}"}
  end

  @doc "Return a map of all registered flags and their current configuration."
  @spec all_flags() :: [map()]
  def all_flags do
    FlagStore.all()
    |> Enum.map(fn {name, cfg} ->
      Map.put(cfg, :name, name)
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Register a new flag with default settings."
  @spec register(flag_name(), map()) :: :ok | {:error, String.t()}
  def register(flag_name, opts \\ %{}) do
    fname = normalise(flag_name)

    if FlagStore.exists?(fname) do
      {:error, "Flag already registered: #{fname}"}
    else
      default = %{rollout_pct: Map.get(opts, :rollout_pct, 0), killed?: false, description: Map.get(opts, :description, "")}
      FlagStore.put(fname, default)
    end
  end

  defp normalise(flag) when is_atom(flag), do: Atom.to_string(flag)
  defp normalise(flag) when is_binary(flag), do: flag
end

# VALIDATION: SMELL END

# ── file: lib/feature_flags/toggle_overrides.ex  (per-user overrides added
#    later; developer accidentally reused the parent module name) ─────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule FeatureFlags.Toggle` replaces the first.
# `enabled?/2`, `enable/2`, `disable/2`, `rollout_percentage/2`, and
# `all_flags/0` all vanish from BEAM, making every feature gate in the
# application silently evaluate to a default (typically `false`).

defmodule FeatureFlags.Toggle do
  @moduledoc """
  Per-user and per-account flag override management.
  Was intended to be `FeatureFlags.Toggle.Overrides` but was accidentally
  given the same module name as the core toggle module.
  """

  alias FeatureFlags.OverrideStore

  @doc "Force a flag on for a specific user, regardless of rollout settings."
  @spec force_on(String.t(), String.t()) :: :ok
  def force_on(flag_name, user_id) do
    OverrideStore.put(flag_name, %{user_id: user_id}, %{value: true})
  end

  @doc "Force a flag off for a specific user."
  @spec force_off(String.t(), String.t()) :: :ok
  def force_off(flag_name, user_id) do
    OverrideStore.put(flag_name, %{user_id: user_id}, %{value: false})
  end

  @doc "Clear any override for a user, reverting to the global rollout rules."
  @spec clear_override(String.t(), String.t()) :: :ok
  def clear_override(flag_name, user_id) do
    OverrideStore.delete(flag_name, %{user_id: user_id})
  end

  @doc "List all active per-user overrides for a flag."
  @spec list_overrides(String.t()) :: [map()]
  def list_overrides(flag_name) do
    OverrideStore.query(flag: flag_name)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc "Bulk-clear all overrides for a flag."
  @spec clear_all_overrides(String.t()) :: {:ok, non_neg_integer()}
  def clear_all_overrides(flag_name) do
    overrides = list_overrides(flag_name)
    Enum.each(overrides, &OverrideStore.delete(flag_name, &1.context))
    {:ok, length(overrides)}
  end
end

# VALIDATION: SMELL END
```
