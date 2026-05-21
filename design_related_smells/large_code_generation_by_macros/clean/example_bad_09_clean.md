```elixir
defmodule UserManagement.RoleDSL do
  @moduledoc """
  Compile-time DSL for declaring user roles and their permission sets.

  Roles are hierarchical. Each role may inherit from a parent role and
  extend its permissions with additional scopes. Roles are registered as
  module attributes so the authorization middleware can resolve them
  without touching the database on the hot path.
  """

  defmacro defrole(role_name, opts) do
    quote do
      role = unquote(role_name)
      opts = unquote(opts)

      unless is_atom(role) do
        raise ArgumentError,
              "role name must be an atom, got: #{inspect(role)}"
      end

      label = Keyword.fetch!(opts, :label)

      unless is_binary(label) do
        raise ArgumentError,
              "role #{inspect(role)} :label must be a binary"
      end

      parent = Keyword.get(opts, :inherits)

      if parent != nil do
        unless is_atom(parent) do
          raise ArgumentError,
                "role #{inspect(role)} :inherits must be an atom role name"
        end
      end

      scopes = Keyword.get(opts, :scopes, [])

      unless is_list(scopes) and Enum.all?(scopes, &is_binary/1) do
        raise ArgumentError,
              "role #{inspect(role)} :scopes must be a list of binary strings"
      end

      visible_in_ui = Keyword.get(opts, :visible_in_ui, true)

      unless is_boolean(visible_in_ui) do
        raise ArgumentError,
              "role #{inspect(role)} :visible_in_ui must be a boolean"
      end

      assignable = Keyword.get(opts, :assignable, true)

      unless is_boolean(assignable) do
        raise ArgumentError,
              "role #{inspect(role)} :assignable must be a boolean"
      end

      max_session_minutes = Keyword.get(opts, :max_session_minutes, 480)

      unless is_integer(max_session_minutes) and max_session_minutes > 0 do
        raise ArgumentError,
              "role #{inspect(role)} :max_session_minutes must be a positive integer"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "role #{inspect(role)} :description must be a binary"
      end

      @user_roles %{
        name:                role,
        label:               label,
        inherits:            parent,
        scopes:              scopes,
        visible_in_ui:       visible_in_ui,
        assignable:          assignable,
        max_session_minutes: max_session_minutes,
        description:         description
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import UserManagement.RoleDSL, only: [defrole: 2]
      Module.register_attribute(__MODULE__, :user_roles, accumulate: true)
      @before_compile UserManagement.RoleDSL
    end
  end

  defmacro __before_compile__(env) do
    roles = Module.get_attribute(env.module, :user_roles)

    quote do
      def roles, do: unquote(Macro.escape(roles))

      def role(name) do
        Enum.find(roles(), &(&1.name == name))
      end

      def all_scopes_for(role_name) do
        case role(role_name) do
          nil  -> []
          r    ->
            parent_scopes =
              case r.inherits do
                nil    -> []
                parent -> all_scopes_for(parent)
              end
            (parent_scopes ++ r.scopes) |> Enum.uniq()
        end
      end

      def assignable_roles do
        Enum.filter(roles(), & &1.assignable)
      end
    end
  end
end

defmodule UserManagement.AppRoles do
  use UserManagement.RoleDSL

  defrole(:viewer,
    label: "Viewer",
    scopes: ["read:own_data"],
    visible_in_ui: true,
    assignable: true,
    max_session_minutes: 60,
    description: "Can only view their own data"
  )

  defrole(:member,
    label: "Member",
    inherits: :viewer,
    scopes: ["write:own_data", "read:team_data"],
    visible_in_ui: true,
    assignable: true,
    max_session_minutes: 480,
    description: "Standard team member"
  )

  defrole(:billing_admin,
    label: "Billing Admin",
    inherits: :member,
    scopes: ["read:billing", "write:billing", "read:invoices", "write:invoices"],
    visible_in_ui: true,
    assignable: true,
    max_session_minutes: 480,
    description: "Manages billing and invoicing"
  )

  defrole(:ops_admin,
    label: "Operations Admin",
    inherits: :member,
    scopes: ["read:shipments", "write:shipments", "read:inventory", "write:inventory"],
    visible_in_ui: true,
    assignable: true,
    max_session_minutes: 480,
    description: "Manages logistics and inventory"
  )

  defrole(:super_admin,
    label: "Super Admin",
    inherits: :ops_admin,
    scopes: ["admin:users", "admin:roles", "admin:billing", "admin:system"],
    visible_in_ui: true,
    assignable: false,
    max_session_minutes: 120,
    description: "Full system access — not directly assignable"
  )

  defrole(:service_account,
    label: "Service Account",
    scopes: ["api:read", "api:write"],
    visible_in_ui: false,
    assignable: false,
    max_session_minutes: 525_600,
    description: "Machine-to-machine accounts"
  )
end
```
