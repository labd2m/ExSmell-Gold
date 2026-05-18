# Annotated Example 11 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro deep_merge/2` inside `Payments.ConfigUtils`
- **Affected function(s):** `deep_merge/2`
- **Short explanation:** The macro recursively merges two maps using only `Map.merge/3` and standard pattern matching — a runtime data transformation with no compile-time component. A regular recursive function is the appropriate abstraction.

---

```elixir
defmodule Payments.ConfigUtils do
  @moduledoc """
  Configuration helpers for the payments subsystem.
  Handles merging of provider-level defaults with per-merchant overrides.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because deep_merge/2 performs a recursive map
  # merge at runtime using standard Map and pattern matching constructs. There
  # is nothing to compute at compile time; a def function is the proper choice.
  defmacro deep_merge(base, override) do
    quote do
      Map.merge(unquote(base), unquote(override), fn _key, v1, v2 ->
        if is_map(v1) and is_map(v2) do
          Payments.ConfigUtils.deep_merge(v1, v2)
        else
          v2
        end
      end)
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Validates that all required payment provider keys are present in the config.
  """
  @spec validate_provider_config(map()) :: :ok | {:error, list(atom())}
  def validate_provider_config(config) do
    required_keys = [:api_key, :endpoint, :timeout_ms, :retry_policy]

    missing =
      Enum.reject(required_keys, fn key -> Map.has_key?(config, key) end)

    if Enum.empty?(missing), do: :ok, else: {:error, missing}
  end

  @doc """
  Applies environment-specific overrides on top of base configuration.
  """
  @spec apply_environment(map(), atom()) :: map()
  def apply_environment(base_config, env) do
    env_overrides =
      case env do
        :production ->
          %{timeout_ms: 5_000, retry_policy: %{max_attempts: 3, backoff: :exponential}}

        :staging ->
          %{timeout_ms: 10_000, retry_policy: %{max_attempts: 2, backoff: :linear}}

        :test ->
          %{timeout_ms: 1_000, retry_policy: %{max_attempts: 1, backoff: :none}}

        _ ->
          %{}
      end

    deep_merge(base_config, env_overrides)
  end
end

defmodule Payments.MerchantConfigService do
  @moduledoc """
  Resolves the effective payment gateway configuration for a given merchant,
  merging global defaults, provider defaults, and merchant-specific overrides.
  """

  require Payments.ConfigUtils

  alias Payments.ConfigUtils

  @global_defaults %{
    currency: "USD",
    capture_mode: :automatic,
    retry_policy: %{
      max_attempts: 2,
      backoff: :linear,
      base_delay_ms: 300
    },
    fraud_checks: %{
      enabled: true,
      min_amount_cents: 1_000
    }
  }

  @doc """
  Resolves the full effective config for a merchant by layering overrides.
  """
  @spec resolve(map(), map(), atom()) :: {:ok, map()} | {:error, list(atom())}
  def resolve(provider_defaults, merchant_overrides, env \\ :production) do
    base = ConfigUtils.deep_merge(@global_defaults, provider_defaults)
    env_adjusted = ConfigUtils.apply_environment(base, env)
    effective = ConfigUtils.deep_merge(env_adjusted, merchant_overrides)

    case ConfigUtils.validate_provider_config(effective) do
      :ok -> {:ok, effective}
      {:error, missing} -> {:error, missing}
    end
  end

  @doc """
  Returns the timeout for a resolved config, with a safe fallback.
  """
  @spec timeout_ms(map()) :: pos_integer()
  def timeout_ms(config) do
    Map.get(config, :timeout_ms, 5_000)
  end

  @doc """
  Returns the maximum retry attempts from the resolved config.
  """
  @spec max_retries(map()) :: non_neg_integer()
  def max_retries(%{retry_policy: %{max_attempts: n}}), do: n
  def max_retries(_), do: 0

  @doc """
  Checks whether fraud checks are enabled for the given config.
  """
  @spec fraud_checks_enabled?(map()) :: boolean()
  def fraud_checks_enabled?(%{fraud_checks: %{enabled: enabled}}), do: enabled
  def fraud_checks_enabled?(_), do: false
end
```
