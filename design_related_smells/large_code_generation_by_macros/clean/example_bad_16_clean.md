```elixir
defmodule Access.PermissionDSL do
  @moduledoc """
  Compile-time DSL for declaring fine-grained access control permissions.

  Permissions bind a resource type to an action and describe conditions under
  which the action may be performed. They support implicit-deny semantics,
  condition chains, and audit log settings.
  """

  @valid_actions [:create, :read, :update, :delete, :list, :export, :approve, :void]
  @valid_effects [:allow, :deny]

  defmacro defpermission(perm_name, opts) do
    quote do
      perm = unquote(perm_name)
      opts = unquote(opts)

      unless is_atom(perm) do
        raise ArgumentError,
              "permission name must be an atom, got: #{inspect(perm)}"
      end

      resource = Keyword.fetch!(opts, :resource)

      unless is_atom(resource) do
        raise ArgumentError,
              "permission #{inspect(perm)} :resource must be an atom"
      end

      action = Keyword.fetch!(opts, :action)

      unless action in unquote(@valid_actions) do
        raise ArgumentError,
              "permission #{inspect(perm)} :action must be one of #{inspect(unquote(@valid_actions))}"
      end

      effect = Keyword.get(opts, :effect, :allow)

      unless effect in unquote(@valid_effects) do
        raise ArgumentError,
              "permission #{inspect(perm)} :effect must be :allow or :deny"
      end

      conditions = Keyword.get(opts, :conditions, [])

      unless is_list(conditions) do
        raise ArgumentError,
              "permission #{inspect(perm)} :conditions must be a list"
      end

      Enum.each(conditions, fn cond ->
        unless is_atom(cond) or (is_tuple(cond) and tuple_size(cond) == 2) do
          raise ArgumentError,
                "permission #{inspect(perm)} each condition must be an atom or 2-tuple"
        end
      end)

      audit = Keyword.get(opts, :audit, true)

      unless is_boolean(audit) do
        raise ArgumentError,
              "permission #{inspect(perm)} :audit must be a boolean"
      end

      justification_required = Keyword.get(opts, :justification_required, false)

      unless is_boolean(justification_required) do
        raise ArgumentError,
              "permission #{inspect(perm)} :justification_required must be a boolean"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "permission #{inspect(perm)} :description must be a binary"
      end

      @access_permissions %{
        name:                   perm,
        resource:               resource,
        action:                 action,
        effect:                 effect,
        conditions:             conditions,
        audit:                  audit,
        justification_required: justification_required,
        description:            description
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Access.PermissionDSL, only: [defpermission: 2]
      Module.register_attribute(__MODULE__, :access_permissions, accumulate: true)
      @before_compile Access.PermissionDSL
    end
  end

  defmacro __before_compile__(env) do
    perms = Module.get_attribute(env.module, :access_permissions)

    quote do
      def permissions, do: unquote(Macro.escape(perms))

      def permission(name) do
        Enum.find(permissions(), &(&1.name == name))
      end

      def permissions_for(resource, action) do
        Enum.filter(permissions(), fn p ->
          p.resource == resource and p.action == action
        end)
      end

      def allowed?(resource, action) do
        case permissions_for(resource, action) do
          []    -> false
          perms -> Enum.any?(perms, &(&1.effect == :allow))
        end
      end
    end
  end
end

defmodule Access.InvoicePermissions do
  use Access.PermissionDSL

  defpermission(:invoice_read,
    resource: :invoice,
    action: :read,
    effect: :allow,
    conditions: [:owner_or_admin],
    audit: false,
    description: "Read own invoice"
  )

  defpermission(:invoice_create,
    resource: :invoice,
    action: :create,
    effect: :allow,
    conditions: [:billing_role],
    audit: true,
    description: "Create a new invoice"
  )

  defpermission(:invoice_update,
    resource: :invoice,
    action: :update,
    effect: :allow,
    conditions: [:billing_role, {:status, :draft}],
    audit: true,
    description: "Update a draft invoice"
  )

  defpermission(:invoice_void,
    resource: :invoice,
    action: :void,
    effect: :allow,
    conditions: [:billing_admin_role],
    audit: true,
    justification_required: true,
    description: "Void a finalized invoice"
  )

  defpermission(:invoice_export,
    resource: :invoice,
    action: :export,
    effect: :allow,
    conditions: [:billing_role],
    audit: true,
    description: "Export invoices to CSV or PDF"
  )

  defpermission(:invoice_delete,
    resource: :invoice,
    action: :delete,
    effect: :deny,
    conditions: [],
    audit: true,
    description: "Invoices may never be deleted"
  )
end
```
