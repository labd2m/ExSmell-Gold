# Annotated Example 18 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defratelimit/2` inside `RateLimiting.LimitDSL`
- **Affected function(s):** `defratelimit/2`
- **Short explanation:** The macro expands all validation—window type, limit bounds, burst multiplier, key strategy, penalty period, and store backend—inline within the quoted block for each rate-limit declaration. Every call causes the compiler to re-expand and recompile this substantial body instead of delegating to a helper function compiled once.

---

```elixir
defmodule RateLimiting.LimitDSL do
  @moduledoc """
  Compile-time DSL for declaring named rate-limit policies.

  Each policy defines a resource/action pair, a sliding or fixed window,
  a request limit, a burst allowance, and what the enforcement back-end
  should do when the limit is exceeded. Policies are validated and
  registered at compile time.
  """

  @valid_window_types [:sliding, :fixed]
  @valid_key_strategies [:ip, :user_id, :api_key, :combined]
  @valid_backends [:redis, :ets, :in_memory]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defratelimit/2 places validation
  # VALIDATION: for resource, action, window type, window size, request limit,
  # VALIDATION: burst multiplier, key strategy, penalty period, and backend
  # VALIDATION: all inside the quoted block. Every policy declaration causes
  # VALIDATION: the compiler to expand and compile this whole body again
  # VALIDATION: instead of calling a helper function compiled only once.
  defmacro defratelimit(policy_name, opts) do
    quote do
      policy = unquote(policy_name)
      opts   = unquote(opts)

      unless is_atom(policy) do
        raise ArgumentError,
              "rate limit policy name must be an atom, got: #{inspect(policy)}"
      end

      resource = Keyword.fetch!(opts, :resource)

      unless is_atom(resource) do
        raise ArgumentError,
              "policy #{inspect(policy)} :resource must be an atom"
      end

      action = Keyword.fetch!(opts, :action)

      unless is_atom(action) do
        raise ArgumentError,
              "policy #{inspect(policy)} :action must be an atom"
      end

      window_type = Keyword.get(opts, :window_type, :sliding)

      unless window_type in unquote(@valid_window_types) do
        raise ArgumentError,
              "policy #{inspect(policy)} :window_type must be :sliding or :fixed"
      end

      window_ms = Keyword.fetch!(opts, :window_ms)

      unless is_integer(window_ms) and window_ms > 0 do
        raise ArgumentError,
              "policy #{inspect(policy)} :window_ms must be a positive integer"
      end

      limit = Keyword.fetch!(opts, :limit)

      unless is_integer(limit) and limit > 0 do
        raise ArgumentError,
              "policy #{inspect(policy)} :limit must be a positive integer"
      end

      burst_multiplier = Keyword.get(opts, :burst_multiplier, 1.0)

      unless is_float(burst_multiplier) and burst_multiplier >= 1.0 do
        raise ArgumentError,
              "policy #{inspect(policy)} :burst_multiplier must be a float >= 1.0"
      end

      key_strategy = Keyword.get(opts, :key_strategy, :user_id)

      unless key_strategy in unquote(@valid_key_strategies) do
        raise ArgumentError,
              "policy #{inspect(policy)} :key_strategy must be one of #{inspect(unquote(@valid_key_strategies))}"
      end

      penalty_ms = Keyword.get(opts, :penalty_ms, 0)

      unless is_integer(penalty_ms) and penalty_ms >= 0 do
        raise ArgumentError,
              "policy #{inspect(policy)} :penalty_ms must be a non-negative integer"
      end

      backend = Keyword.get(opts, :backend, :redis)

      unless backend in unquote(@valid_backends) do
        raise ArgumentError,
              "policy #{inspect(policy)} :backend must be one of #{inspect(unquote(@valid_backends))}"
      end

      @rate_limit_policies %{
        name:             policy,
        resource:         resource,
        action:           action,
        window_type:      window_type,
        window_ms:        window_ms,
        limit:            limit,
        burst_multiplier: burst_multiplier,
        key_strategy:     key_strategy,
        penalty_ms:       penalty_ms,
        backend:          backend
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import RateLimiting.LimitDSL, only: [defratelimit: 2]
      Module.register_attribute(__MODULE__, :rate_limit_policies, accumulate: true)
      @before_compile RateLimiting.LimitDSL
    end
  end

  defmacro __before_compile__(env) do
    policies = Module.get_attribute(env.module, :rate_limit_policies)

    quote do
      def policies, do: unquote(Macro.escape(policies))

      def policy(name) do
        Enum.find(policies(), &(&1.name == name))
      end

      def policy_for(resource, action) do
        Enum.find(policies(), fn p ->
          p.resource == resource and p.action == action
        end)
      end
    end
  end
end

defmodule RateLimiting.AppPolicies do
  use RateLimiting.LimitDSL

  defratelimit(:api_login,
    resource: :auth,
    action: :login,
    window_type: :fixed,
    window_ms: 60_000,
    limit: 10,
    burst_multiplier: 1.0,
    key_strategy: :ip,
    penalty_ms: 300_000,
    backend: :redis
  )

  defratelimit(:api_invoice_create,
    resource: :invoice,
    action: :create,
    window_type: :sliding,
    window_ms: 60_000,
    limit: 30,
    burst_multiplier: 1.5,
    key_strategy: :user_id,
    penalty_ms: 0,
    backend: :redis
  )

  defratelimit(:api_payment_capture,
    resource: :payment,
    action: :capture,
    window_type: :fixed,
    window_ms: 60_000,
    limit: 10,
    burst_multiplier: 1.0,
    key_strategy: :user_id,
    penalty_ms: 60_000,
    backend: :redis
  )

  defratelimit(:api_report_export,
    resource: :report,
    action: :export,
    window_type: :sliding,
    window_ms: 3_600_000,
    limit: 5,
    burst_multiplier: 1.2,
    key_strategy: :api_key,
    penalty_ms: 0,
    backend: :redis
  )

  defratelimit(:api_user_search,
    resource: :user,
    action: :search,
    window_type: :sliding,
    window_ms: 60_000,
    limit: 120,
    burst_multiplier: 2.0,
    key_strategy: :user_id,
    penalty_ms: 0,
    backend: :ets
  )

  defratelimit(:api_webhook_delivery,
    resource: :webhook,
    action: :deliver,
    window_type: :sliding,
    window_ms: 1_000,
    limit: 50,
    burst_multiplier: 1.5,
    key_strategy: :combined,
    penalty_ms: 0,
    backend: :redis
  )
end
```
