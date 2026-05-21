```elixir
defmodule MyApp.RBAC do
  @moduledoc """
  Role-Based Access Control DSL.

  Provides a declarative way to define which roles are allowed to perform
  specific actions on application resources.

  ## Usage

      defmodule MyApp.InvoicePolicy do
        use MyApp.RBAC

        allow :invoice, :read,   [:viewer, :editor, :admin]
        allow :invoice, :create, [:editor, :admin]
        allow :invoice, :update, [:editor, :admin]
        allow :invoice, :delete, [:admin]
        allow :invoice, :export, [:manager, :admin]
      end

  Each `allow/3` call also generates a convenience predicate such as
  `can_read_invoice?(user)` in the calling module.
  """

  @valid_roles [:guest, :viewer, :editor, :manager, :admin, :superadmin]

  defmacro __using__(_opts) do
    quote do
      import MyApp.RBAC, only: [allow: 3]
      Module.register_attribute(__MODULE__, :rbac_rules, accumulate: true)
      @before_compile MyApp.RBAC
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns all RBAC rules registered in this policy."
      def __rbac_rules__, do: @rbac_rules

      @doc """
      Returns `true` when the given `user` (a map with a `:role` key) is
      authorised to perform `action` on `resource`.
      """
      def authorized?(%{role: role}, resource, action) do
        Enum.any?(@rbac_rules, fn {r, a, roles} ->
          r == resource and a == action and role in roles
        end)
      end

      def authorized?(_user, _resource, _action), do: false
    end
  end

  defmacro allow(resource, action, roles) do
    quote do
      unless is_atom(unquote(resource)) do
        raise ArgumentError,
              "[RBAC] `resource` must be an atom, got: #{inspect(unquote(resource))}"
      end

      unless is_atom(unquote(action)) do
        raise ArgumentError,
              "[RBAC] `action` must be an atom, got: #{inspect(unquote(action))}"
      end

      unless is_list(unquote(roles)) do
        raise ArgumentError,
              "[RBAC] `roles` must be a list of atoms, got: #{inspect(unquote(roles))}"
      end

      Enum.each(unquote(roles), fn role ->
        unless role in unquote(@valid_roles) do
          raise ArgumentError,
                "[RBAC] Unknown role #{inspect(role)}. " <>
                  "Valid roles are: #{inspect(unquote(@valid_roles))}"
        end
      end)

      @rbac_rules {unquote(resource), unquote(action), unquote(roles)}

      @doc """
      Returns `true` when the `:role` key in `user` is allowed to
      perform `#{unquote(action)}` on `#{unquote(resource)}`.
      """
      def unquote(:"can_#{action}_#{resource}?")(user) do
        role = Map.get(user, :role, :guest)

        cond do
          role == :superadmin -> true
          role in unquote(roles) -> true
          true -> false
        end
      end
    end
  end

  @doc """
  Returns the list of all valid roles recognised by the RBAC system.
  """
  def valid_roles, do: @valid_roles
end
```
