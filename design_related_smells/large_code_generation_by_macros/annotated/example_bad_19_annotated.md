# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro permission/2` inside `MyApp.Authorization`
- **Affected function(s):** `permission/2` macro
- **Short explanation:** Every call to `permission/2` expands a large `quote` block containing validation logic, guard checks, logging, and module-attribute manipulation directly inside the macro body. This forces the Elixir compiler to expand, compile, and evaluate all of that code for every single invocation, inflating compilation time and binary size. The bulk of the logic should be delegated to a regular function.

---

```elixir
defmodule MyApp.Authorization do
  @moduledoc """
  DSL for declaring resource-level permissions on controller modules.
  Usage:

      defmodule MyApp.InvoiceController do
        use MyApp.Authorization

        permission :read,   MyApp.Policies.InvoiceRead
        permission :write,  MyApp.Policies.InvoiceWrite
        permission :delete, MyApp.Policies.InvoiceDelete
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Authorization, only: [permission: 2]
      Module.register_attribute(__MODULE__, :declared_permissions, accumulate: true)
      @before_compile MyApp.Authorization
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __permissions__, do: @declared_permissions
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because the entire body of the quote block is
  # VALIDATION: inlined on every call to permission/2. Each invocation expands
  # VALIDATION: argument validation, type checks, debug logging, and the
  # VALIDATION: module-attribute registration directly at the call site,
  # VALIDATION: instead of delegating to a plain function.
  defmacro permission(action, policy_module) do
    quote do
      action        = unquote(action)
      policy_module = unquote(policy_module)

      unless is_atom(action) do
        raise ArgumentError,
              "permission/2 expects an atom as the first argument, got: #{inspect(action)}"
      end

      unless is_atom(policy_module) do
        raise ArgumentError,
              "permission/2 expects a module atom as the second argument, " <>
                "got: #{inspect(policy_module)}"
      end

      valid_actions = [:read, :write, :delete, :admin, :export, :import, :approve]

      unless action in valid_actions do
        raise ArgumentError,
              "Unknown action #{inspect(action)}. " <>
                "Valid actions are: #{inspect(valid_actions)}"
      end

      existing = Module.get_attribute(__MODULE__, :declared_permissions)

      if Enum.any?(existing, fn {a, _} -> a == action end) do
        raise ArgumentError,
              "Action #{inspect(action)} is already declared in #{inspect(__MODULE__)}"
      end

      :ok = Code.ensure_compiled!(policy_module)

      unless function_exported?(policy_module, :authorize, 2) do
        raise ArgumentError,
              "Policy module #{inspect(policy_module)} must export authorize/2"
      end

      unless function_exported?(policy_module, :scope, 1) do
        raise ArgumentError,
              "Policy module #{inspect(policy_module)} must export scope/1"
      end

      require Logger
      Logger.debug(fn ->
        "[Authorization] Registering permission #{inspect(action)} " <>
          "=> #{inspect(policy_module)} on #{inspect(__MODULE__)}"
      end)

      @declared_permissions {action, policy_module}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Checks whether the given user is allowed to perform `action` on `resource`
  according to the permissions declared on `controller`.
  """
  @spec allowed?(module(), atom(), map(), any()) :: boolean()
  def allowed?(controller, action, user, resource) do
    case List.keyfind(controller.__permissions__(), action, 0) do
      nil ->
        false

      {^action, policy_module} ->
        case policy_module.authorize(user, resource) do
          :ok              -> true
          {:ok, _}         -> true
          :error           -> false
          {:error, _}      -> false
        end
    end
  end

  @doc """
  Returns a scoped query for the given user using the policy registered for
  `action` on `controller`.
  """
  @spec scope(module(), atom(), map()) :: any()
  def scope(controller, action, user) do
    case List.keyfind(controller.__permissions__(), action, 0) do
      nil ->
        raise "No permission declared for #{inspect(action)} on #{inspect(controller)}"

      {^action, policy_module} ->
        policy_module.scope(user)
    end
  end
end
```
