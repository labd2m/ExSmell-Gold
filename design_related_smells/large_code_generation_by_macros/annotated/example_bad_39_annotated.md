# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro rate_limit/2` inside `MyApp.RateLimiter.RuleDSL`
- **Affected function(s):** `rate_limit/2` macro
- **Short explanation:** Every call to `rate_limit/2` expands a large `quote` block that validates the rule name, window size, max-requests value, scope option, burst allowance, backend module callbacks, penalty TTL, and deduplication — all inline at the call site. A module declaring many rate-limit rules will have this entire block compiled once per declaration rather than delegating to a shared helper function.

---

```elixir
defmodule MyApp.RateLimiter.RuleDSL do
  @moduledoc """
  DSL for declaring rate-limiting rules within a limiter configuration module.

  Example:

      defmodule MyApp.RateLimiter.ApiLimits do
        use MyApp.RateLimiter.RuleDSL, backend: MyApp.RateLimiter.RedisBackend

        rate_limit :public_api,
          window_seconds: 60,
          max_requests:   100,
          scope:          :ip,
          burst:          20,
          penalty_ttl:    300

        rate_limit :authenticated_api,
          window_seconds: 60,
          max_requests:   1_000,
          scope:          :user_id,
          burst:          100

        rate_limit :payment_endpoint,
          window_seconds: 3_600,
          max_requests:   10,
          scope:          :user_id,
          penalty_ttl:    7_200
      end
  """

  defmacro __using__(opts) do
    backend = Keyword.get(opts, :backend, MyApp.RateLimiter.ETSBackend)

    quote do
      import MyApp.RateLimiter.RuleDSL, only: [rate_limit: 2]
      Module.register_attribute(__MODULE__, :rate_limit_rules, accumulate: true)
      @rate_limit_backend unquote(backend)
      @before_compile MyApp.RateLimiter.RuleDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def rate_limit_rules,   do: @rate_limit_rules
      def rate_limit_backend, do: @rate_limit_backend

      def rule(name) do
        Enum.find(@rate_limit_rules, fn r -> r.name == name end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to rate_limit/2 causes the
  # VALIDATION: Elixir compiler to expand and compile this entire block at the
  # VALIDATION: call site: name atom check, window_seconds positive-integer check,
  # VALIDATION: max_requests positive-integer check, scope enumeration check,
  # VALIDATION: burst integer check, backend compilation and increment/1 + check/1
  # VALIDATION: callback checks, penalty_ttl check, deduplication guard, and rule
  # VALIDATION: struct construction. A limiter module with ten rules compiles all
  # VALIDATION: of this code ten times rather than once inside a shared function.
  defmacro rate_limit(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "rate_limit/2: name must be an atom, got #{inspect(name)}"
      end

      window_seconds = Keyword.fetch!(opts, :window_seconds)

      unless is_integer(window_seconds) and window_seconds > 0 do
        raise ArgumentError,
              "rate_limit/2: :window_seconds must be a positive integer, " <>
                "got #{inspect(window_seconds)}"
      end

      max_requests = Keyword.fetch!(opts, :max_requests)

      unless is_integer(max_requests) and max_requests > 0 do
        raise ArgumentError,
              "rate_limit/2: :max_requests must be a positive integer, " <>
                "got #{inspect(max_requests)}"
      end

      valid_scopes = [:ip, :user_id, :api_key, :global]
      scope = Keyword.get(opts, :scope, :ip)

      unless scope in valid_scopes do
        raise ArgumentError,
              "rate_limit/2: :scope must be one of #{inspect(valid_scopes)}, " <>
                "got #{inspect(scope)}"
      end

      burst = Keyword.get(opts, :burst, 0)

      unless is_integer(burst) and burst >= 0 do
        raise ArgumentError,
              "rate_limit/2: :burst must be a non-negative integer, got #{inspect(burst)}"
      end

      unless burst < max_requests do
        raise ArgumentError,
              "rate_limit/2: :burst (#{burst}) must be less than :max_requests (#{max_requests})"
      end

      backend = Module.get_attribute(__MODULE__, :rate_limit_backend)
      :ok     = Code.ensure_compiled!(backend)

      unless function_exported?(backend, :increment, 2) do
        raise ArgumentError,
              "rate_limit/2: backend #{inspect(backend)} must export increment/2"
      end

      unless function_exported?(backend, :check, 2) do
        raise ArgumentError,
              "rate_limit/2: backend #{inspect(backend)} must export check/2"
      end

      penalty_ttl = Keyword.get(opts, :penalty_ttl, 0)

      unless is_integer(penalty_ttl) and penalty_ttl >= 0 do
        raise ArgumentError,
              "rate_limit/2: :penalty_ttl must be a non-negative integer (seconds), " <>
                "got #{inspect(penalty_ttl)}"
      end

      existing = Module.get_attribute(__MODULE__, :rate_limit_rules)

      if Enum.any?(existing, fn r -> r.name == name end) do
        raise ArgumentError,
              "rate_limit/2: duplicate rule #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      rule = %{
        name:           name,
        window_seconds: window_seconds,
        max_requests:   max_requests,
        scope:          scope,
        burst:          burst,
        penalty_ttl:    penalty_ttl
      }

      @rate_limit_rules rule
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Checks and increments the counter for `identifier` against the named rule.
  Returns `:ok` if allowed or `{:error, :rate_limited, retry_after_seconds}`.
  """
  @spec check_and_increment(module(), atom(), String.t()) ::
          :ok | {:error, :rate_limited, pos_integer()}
  def check_and_increment(limiter_module, rule_name, identifier) do
    backend = limiter_module.rate_limit_backend()

    case limiter_module.rule(rule_name) do
      nil ->
        raise "Unknown rate limit rule: #{inspect(rule_name)}"

      rule ->
        key = "#{rule_name}:#{identifier}"

        case backend.check(key, rule) do
          :allow ->
            backend.increment(key, rule)
            :ok

          {:deny, retry_after} ->
            {:error, :rate_limited, retry_after}
        end
    end
  end

  @doc """
  Returns the current request count for `identifier` under the given rule.
  """
  @spec current_count(module(), atom(), String.t()) :: non_neg_integer()
  def current_count(limiter_module, rule_name, identifier) do
    backend = limiter_module.rate_limit_backend()
    key     = "#{rule_name}:#{identifier}"
    backend.get_count(key)
  end
end
```
