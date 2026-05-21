```elixir
defmodule MyApp.UserManagement.RoleDSL do
  @moduledoc """
  DSL for declaring user roles and their associated permissions.

  Example:

      defmodule MyApp.UserManagement.Roles do
        use MyApp.UserManagement.RoleDSL

        define_role :viewer,
          permissions: [:read_reports, :view_dashboard],
          description: "Read-only access"

        define_role :editor,
          permissions: [:read_reports, :view_dashboard, :edit_content, :upload_files],
          inherits:    :viewer,
          description: "Content management access"

        define_role :admin,
          permissions: :all,
          inherits:    :editor,
          description: "Full system access"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.UserManagement.RoleDSL, only: [define_role: 2]
      Module.register_attribute(__MODULE__, :roles, accumulate: true)
      @before_compile MyApp.UserManagement.RoleDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def roles, do: @roles

      def role(name) do
        Enum.find(@roles, fn r -> r.name == name end)
      end

      def has_permission?(role_name, permission) do
        case role(role_name) do
          nil  -> false
          role -> role.permissions == :all or permission in role.permissions
        end
      end
    end
  end

  defmacro define_role(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "define_role/2: role name must be an atom, got #{inspect(name)}"
      end

      permissions = Keyword.fetch!(opts, :permissions)

      unless permissions == :all or
               (is_list(permissions) and Enum.all?(permissions, &is_atom/1)) do
        raise ArgumentError,
              "define_role/2: :permissions must be :all or a list of atoms, " <>
                "got #{inspect(permissions)}"
      end

      if is_list(permissions) and Enum.empty?(permissions) do
        raise ArgumentError,
              "define_role/2: :permissions list must not be empty for role #{inspect(name)}"
      end

      inherits = Keyword.get(opts, :inherits)

      if not is_nil(inherits) and not is_atom(inherits) do
        raise ArgumentError,
              "define_role/2: :inherits must be an atom role name or nil, " <>
                "got #{inspect(inherits)}"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "define_role/2: :description must be a string, got #{inspect(description)}"
      end

      existing = Module.get_attribute(__MODULE__, :roles)

      if Enum.any?(existing, fn r -> r.name == name end) do
        raise ArgumentError,
              "define_role/2: duplicate role #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      if not is_nil(inherits) and not Enum.any?(existing, fn r -> r.name == inherits end) do
        raise ArgumentError,
              "define_role/2: :inherits references unknown role #{inspect(inherits)}. " <>
                "Roles must be declared in order."
      end

      role = %{
        name:        name,
        permissions: permissions,
        inherits:    inherits,
        description: description
      }

      @roles role
    end
  end

  @doc """
  Returns the effective (inherited) permission set for a role in the given
  role-definition module.
  """
  @spec effective_permissions(module(), atom()) :: :all | [atom()]
  def effective_permissions(roles_module, role_name) do
    case roles_module.role(role_name) do
      nil ->
        raise "Unknown role: #{inspect(role_name)}"

      %{permissions: :all} ->
        :all

      %{permissions: perms, inherits: nil} ->
        perms

      %{permissions: perms, inherits: parent} ->
        case effective_permissions(roles_module, parent) do
          :all           -> :all
          parent_perms   -> Enum.uniq(parent_perms ++ perms)
        end
    end
  end
end
```
