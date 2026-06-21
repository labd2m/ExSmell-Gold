# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro tenant_scope/2` inside `MyApp.Multitenancy.ScopeDSL`
- **Affected function(s):** `tenant_scope/2` macro
- **Short explanation:** Every call to `tenant_scope/2` expands a large `quote` block inlining schema module compilation checks, tenant-key field validation, isolation strategy enumeration, fallback behaviour checks, repo module validation, deduplication guards, and scope-function generation — entirely at the call site. A multitenancy module declaring many scoped resources forces the compiler to expand and compile all of this code for every declaration.

---

```elixir
defmodule MyApp.Multitenancy.ScopeDSL do
  @moduledoc """
  DSL for declaring tenant-scoped database resources in a multitenancy module.

  Example:

      defmodule MyApp.Multitenancy.TenantScopes do
        use MyApp.Multitenancy.ScopeDSL, repo: MyApp.Repo

        tenant_scope MyApp.Schemas.Invoice,
          tenant_key:  :org_id,
          strategy:    :field,
          fallback:    :raise,
          description: "Invoices are scoped to organisation"

        tenant_scope MyApp.Schemas.User,
          tenant_key:  :org_id,
          strategy:    :field,
          fallback:    :empty,
          description: "Users are scoped to organisation"

        tenant_scope MyApp.Schemas.AuditLog,
          tenant_key:  :tenant_id,
          strategy:    :prefix,
          fallback:    :raise,
          description: "Audit logs use schema-prefix isolation"
      end
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)

    quote do
      import MyApp.Multitenancy.ScopeDSL, only: [tenant_scope: 2]
      Module.register_attribute(__MODULE__, :tenant_scopes, accumulate: true)
      @tenant_repo unquote(repo)
      @before_compile MyApp.Multitenancy.ScopeDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def tenant_scopes, do: @tenant_scopes
      def tenant_repo,   do: @tenant_repo

      def scope_for(schema) do
        Enum.find(@tenant_scopes, fn s -> s.schema == schema end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to tenant_scope/2 expands
  # VALIDATION: this entire block inline: schema module compilation check,
  # VALIDATION: tenant_key atom check, field-existence verification on the schema,
  # VALIDATION: isolation strategy enumeration check, fallback option enumeration
  # VALIDATION: check, description string check, repo module compilation and
  # VALIDATION: callback check, deduplication guard, and scope struct construction.
  # VALIDATION: A module scoping many resources compiles all of this once per
  # VALIDATION: declaration rather than delegating to a shared helper function.
  defmacro tenant_scope(schema_module, opts) do
    quote do
      schema_module = unquote(schema_module)
      opts          = unquote(opts)

      unless is_atom(schema_module) do
        raise ArgumentError,
              "tenant_scope/2: schema must be a module atom, got #{inspect(schema_module)}"
      end

      :ok = Code.ensure_compiled!(schema_module)

      unless function_exported?(schema_module, :__schema__, 1) do
        raise ArgumentError,
              "tenant_scope/2: #{inspect(schema_module)} does not appear to be an Ecto schema"
      end

      tenant_key = Keyword.fetch!(opts, :tenant_key)

      unless is_atom(tenant_key) do
        raise ArgumentError,
              "tenant_scope/2: :tenant_key must be an atom, got #{inspect(tenant_key)}"
      end

      schema_fields = schema_module.__schema__(:fields)

      unless tenant_key in schema_fields do
        raise ArgumentError,
              "tenant_scope/2: field #{inspect(tenant_key)} does not exist on " <>
                "#{inspect(schema_module)}. Known fields: #{inspect(schema_fields)}"
      end

      valid_strategies = [:field, :prefix, :row_security]
      strategy = Keyword.get(opts, :strategy, :field)

      unless strategy in valid_strategies do
        raise ArgumentError,
              "tenant_scope/2: :strategy must be one of #{inspect(valid_strategies)}, " <>
                "got #{inspect(strategy)}"
      end

      valid_fallbacks = [:raise, :empty, :nil]
      fallback = Keyword.get(opts, :fallback, :raise)

      unless fallback in valid_fallbacks do
        raise ArgumentError,
              "tenant_scope/2: :fallback must be one of #{inspect(valid_fallbacks)}, " <>
                "got #{inspect(fallback)}"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "tenant_scope/2: :description must be a string, got #{inspect(description)}"
      end

      repo = Module.get_attribute(__MODULE__, :tenant_repo)
      :ok  = Code.ensure_compiled!(repo)

      unless function_exported?(repo, :all, 2) do
        raise ArgumentError,
              "tenant_scope/2: repo #{inspect(repo)} does not look like an Ecto.Repo"
      end

      existing = Module.get_attribute(__MODULE__, :tenant_scopes)

      if Enum.any?(existing, fn s -> s.schema == schema_module end) do
        raise ArgumentError,
              "tenant_scope/2: duplicate scope for #{inspect(schema_module)} " <>
                "in #{inspect(__MODULE__)}"
      end

      scope_entry = %{
        schema:      schema_module,
        tenant_key:  tenant_key,
        strategy:    strategy,
        fallback:    fallback,
        description: description
      }

      @tenant_scopes scope_entry
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns a base query for `schema` scoped to the given `tenant_id`.
  Raises if no scope is registered and fallback is :raise; returns an
  empty list query if fallback is :empty.
  """
  @spec scoped_query(module(), module(), any()) :: Ecto.Query.t()
  def scoped_query(scopes_module, schema, tenant_id) do
    import Ecto.Query, only: [from: 2, where: 3]

    case scopes_module.scope_for(schema) do
      nil ->
        raise "No tenant scope registered for #{inspect(schema)}"

      %{strategy: :field, tenant_key: key, fallback: :raise} when is_nil(tenant_id) ->
        raise "tenant_id is required for scoped query on #{inspect(schema)}"

      %{strategy: :field, tenant_key: _key, fallback: :empty} when is_nil(tenant_id) ->
        from(s in schema, where: false)

      %{strategy: :field, tenant_key: key} ->
        from(s in schema, where: field(s, ^key) == ^tenant_id)

      %{strategy: :prefix} ->
        from(s in {Atom.to_string(tenant_id) <> "_" <> schema.__schema__(:source), schema},
             select: s)
    end
  end
end
```
