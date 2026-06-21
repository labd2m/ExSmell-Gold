# Annotated Example 03 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defpolicy/3` inside `Auth.PolicyDSL`
- **Affected function(s):** `defpolicy/3`
- **Short explanation:** The macro generates a sizeable block of argument validation, scope resolution, and module-attribute registration on every invocation. All of that logic is re-expanded and re-compiled at each call site rather than being pushed into a shared helper function.

---

```elixir
defmodule Auth.PolicyDSL do
  @moduledoc """
  Compile-time DSL for declaring authorization policies.
  Each policy binds a resource type, an action, and a set of
  required scopes, along with optional audit and rate-limit metadata.
  """

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because the entire validation pipeline—
  # VALIDATION: type checks on resource, action, scopes, audit flag, and
  # VALIDATION: rate limits—is expanded inline by the compiler for every
  # VALIDATION: single defpolicy/3 call. Moving this logic to a plain
  # VALIDATION: function would compile it once and dispatch at runtime.
  defmacro defpolicy(resource, action, opts \\ []) do
    quote do
      resource = unquote(resource)
      action   = unquote(action)
      opts     = unquote(opts)

      unless is_atom(resource) do
        raise ArgumentError,
              "policy resource must be an atom, got: #{inspect(resource)}"
      end

      unless is_atom(action) do
        raise ArgumentError,
              "policy action must be an atom, got: #{inspect(action)}"
      end

      required_scopes = Keyword.get(opts, :scopes, [])

      unless is_list(required_scopes) and Enum.all?(required_scopes, &is_binary/1) do
        raise ArgumentError,
              "policy #{inspect(resource)}.#{inspect(action)} :scopes must be a list of strings"
      end

      audit = Keyword.get(opts, :audit, true)

      unless is_boolean(audit) do
        raise ArgumentError,
              "policy #{inspect(resource)}.#{inspect(action)} :audit must be a boolean"
      end

      rate_limit = Keyword.get(opts, :rate_limit)

      if rate_limit != nil do
        unless is_integer(rate_limit) and rate_limit > 0 do
          raise ArgumentError,
                "policy #{inspect(resource)}.#{inspect(action)} :rate_limit must be a positive integer"
        end
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "policy #{inspect(resource)}.#{inspect(action)} :description must be a string"
      end

      mfa_required = Keyword.get(opts, :mfa_required, false)

      unless is_boolean(mfa_required) do
        raise ArgumentError,
              "policy #{inspect(resource)}.#{inspect(action)} :mfa_required must be a boolean"
      end

      @auth_policies %{
        resource:      resource,
        action:        action,
        scopes:        required_scopes,
        audit:         audit,
        rate_limit:    rate_limit,
        description:   description,
        mfa_required:  mfa_required
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Auth.PolicyDSL, only: [defpolicy: 2, defpolicy: 3]
      Module.register_attribute(__MODULE__, :auth_policies, accumulate: true)
      @before_compile Auth.PolicyDSL
    end
  end

  defmacro __before_compile__(env) do
    policies = Module.get_attribute(env.module, :auth_policies)

    quote do
      def policies, do: unquote(Macro.escape(policies))

      def policy_for(resource, action) do
        Enum.find(policies(), fn p ->
          p.resource == resource and p.action == action
        end)
      end

      def required_scopes(resource, action) do
        case policy_for(resource, action) do
          nil    -> {:error, :unknown_policy}
          policy -> {:ok, policy.scopes}
        end
      end

      def authorized?(resource, action, user_scopes) do
        case policy_for(resource, action) do
          nil    -> false
          policy -> Enum.all?(policy.scopes, &(&1 in user_scopes))
        end
      end
    end
  end
end

defmodule Auth.AppPolicies do
  use Auth.PolicyDSL

  defpolicy(:invoice, :read,
    scopes: ["invoices:read"],
    audit: false,
    description: "Read a single invoice"
  )

  defpolicy(:invoice, :create,
    scopes: ["invoices:write"],
    audit: true,
    description: "Create a new invoice"
  )

  defpolicy(:invoice, :void,
    scopes: ["invoices:write", "invoices:void"],
    audit: true,
    mfa_required: true,
    description: "Void an existing invoice"
  )

  defpolicy(:payment, :capture,
    scopes: ["payments:write"],
    audit: true,
    rate_limit: 10,
    mfa_required: true,
    description: "Capture a pre-authorized payment"
  )

  defpolicy(:user, :delete,
    scopes: ["users:admin"],
    audit: true,
    mfa_required: true,
    description: "Delete a user account"
  )

  defpolicy(:report, :export,
    scopes: ["reports:read"],
    audit: true,
    rate_limit: 5,
    description: "Export a report to CSV or PDF"
  )
end
```
