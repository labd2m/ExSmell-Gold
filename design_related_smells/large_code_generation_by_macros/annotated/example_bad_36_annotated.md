# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro policy/3` inside `MyApp.AccessControl.PolicyDSL`
- **Affected function(s):** `policy/3` macro
- **Short explanation:** Every invocation of `policy/3` expands a large `quote` block that validates the resource type, action atom, condition function arity, fallback option, scope function arity, error message, and deduplication — entirely inline. A large access control module defining many policies will have the compiler expand and compile all of this code at each declaration site.

---

```elixir
defmodule MyApp.AccessControl.PolicyDSL do
  @moduledoc """
  DSL for declaring fine-grained access control policies.

  Example:

      defmodule MyApp.AccessControl.Policies do
        use MyApp.AccessControl.PolicyDSL

        policy MyApp.Schemas.Invoice, :read,
          condition: &match?(%{role: :admin}, &1.actor),
          error:     "Not authorised to read invoices"

        policy MyApp.Schemas.Invoice, :write,
          condition: fn ctx -> ctx.actor.role in [:admin, :accountant] end,
          scope:     fn ctx -> where(Invoice, [i], i.org_id == ^ctx.actor.org_id) end,
          error:     "Not authorised to write invoices"

        policy MyApp.Schemas.Report, :export,
          condition: &match?(%{role: :admin}, &1.actor),
          fallback:  :deny,
          error:     "Only admins may export reports"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.AccessControl.PolicyDSL, only: [policy: 3]
      Module.register_attribute(__MODULE__, :policies, accumulate: true)
      @before_compile MyApp.AccessControl.PolicyDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def policies, do: @policies

      def policy_for(resource, action) do
        Enum.find(@policies, fn p ->
          p.resource == resource and p.action == action
        end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to policy/3 expands this
  # VALIDATION: entire block inline: resource atom check, action atom check,
  # VALIDATION: condition function-arity check, fallback enumeration check,
  # VALIDATION: scope function arity check, error string check, deduplication
  # VALIDATION: guard, and policy struct construction. An access control module
  # VALIDATION: with many policies compiles this code once per policy declaration
  # VALIDATION: rather than delegating to a shared function.
  defmacro policy(resource, action, opts) do
    quote do
      resource = unquote(resource)
      action   = unquote(action)
      opts     = unquote(opts)

      unless is_atom(resource) do
        raise ArgumentError,
              "policy/3: resource must be a module atom, got #{inspect(resource)}"
      end

      unless is_atom(action) do
        raise ArgumentError,
              "policy/3: action must be an atom, got #{inspect(action)}"
      end

      condition = Keyword.fetch!(opts, :condition)

      unless is_function(condition, 1) do
        raise ArgumentError,
              "policy/3: :condition must be a 1-arity function, got #{inspect(condition)}"
      end

      valid_fallbacks = [:allow, :deny]
      fallback = Keyword.get(opts, :fallback, :deny)

      unless fallback in valid_fallbacks do
        raise ArgumentError,
              "policy/3: :fallback must be one of #{inspect(valid_fallbacks)}, " <>
                "got #{inspect(fallback)}"
      end

      scope = Keyword.get(opts, :scope)

      if not is_nil(scope) do
        unless is_function(scope, 1) do
          raise ArgumentError,
                "policy/3: :scope must be a 1-arity function, got #{inspect(scope)}"
        end
      end

      error_msg = Keyword.get(opts, :error, "Access denied")

      unless is_binary(error_msg) and byte_size(error_msg) > 0 do
        raise ArgumentError,
              "policy/3: :error must be a non-empty string, got #{inspect(error_msg)}"
      end

      existing = Module.get_attribute(__MODULE__, :policies)

      if Enum.any?(existing, fn p -> p.resource == resource and p.action == action end) do
        raise ArgumentError,
              "policy/3: duplicate policy for {#{inspect(resource)}, #{inspect(action)}} " <>
                "in #{inspect(__MODULE__)}"
      end

      pol = %{
        resource:  resource,
        action:    action,
        condition: condition,
        fallback:  fallback,
        scope:     scope,
        error:     error_msg
      }

      @policies pol
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Evaluates whether the action is permitted given the context.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec check(module(), atom(), atom(), map()) :: :ok | {:error, String.t()}
  def check(policy_module, resource, action, context) do
    case policy_module.policy_for(resource, action) do
      nil ->
        {:error, "No policy defined for #{inspect(resource)} / #{inspect(action)}"}

      pol ->
        allowed =
          try do
            pol.condition.(context)
          rescue
            _ -> pol.fallback == :allow
          end

        if allowed, do: :ok, else: {:error, pol.error}
    end
  end

  @doc """
  Returns a scoped query for the given resource/action pair, if a `:scope`
  function is registered in the policy.
  """
  @spec scope(module(), atom(), atom(), map()) :: any() | nil
  def scope(policy_module, resource, action, context) do
    case policy_module.policy_for(resource, action) do
      nil                      -> nil
      %{scope: nil}            -> nil
      %{scope: scope_fn}       -> scope_fn.(context)
    end
  end
end
```
