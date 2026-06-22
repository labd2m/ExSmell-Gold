```elixir
defmodule Access.FieldGuard do
  @moduledoc """
  Provides declarative, role-based field-level access control for Ecto query
  results. Fields that the requesting actor is not permitted to see are
  replaced with a sentinel value before the data leaves the database layer,
  ensuring sensitive columns are never accidentally exposed in serialised
  responses. Policies are defined as module attributes so they are validated
  at compile time rather than discovered at runtime.
  """

  @sentinel :__redacted__

  @doc """
  Filters the fields of `record` (or a list of records) based on the
  permissions granted to `actor` by `policy_module`. Unauthorised fields
  are set to `#{inspect(@sentinel)}` so callers can detect redaction
  explicitly rather than receiving nil (which could be a legitimate value).
  """
  @spec filter(struct() | [struct()], map(), module()) :: struct() | [struct()]
  def filter(records, actor, policy_module) when is_list(records) do
    Enum.map(records, &filter(&1, actor, policy_module))
  end

  def filter(%{} = record, actor, policy_module) when is_map(actor) do
    schema = record.__struct__
    all_fields = Map.keys(record) -- [:__struct__, :__meta__]

    permitted = policy_module.permitted_fields(actor, schema)

    Enum.reduce(all_fields, record, fn field, acc ->
      if field in permitted do
        acc
      else
        Map.put(acc, field, @sentinel)
      end
    end)
  end

  @doc """
  Returns `true` when `field` in `record` has been redacted.
  """
  @spec redacted?(map(), atom()) :: boolean()
  def redacted?(record, field) when is_map(record) and is_atom(field) do
    Map.get(record, field) == @sentinel
  end

  @doc """
  Strips all redacted fields from `record`, returning only permitted fields.
  Use when the consuming system should not even know redacted fields exist.
  """
  @spec strip_redacted(map()) :: map()
  def strip_redacted(record) when is_map(record) do
    record
    |> Map.reject(fn {_k, v} -> v == @sentinel end)
    |> Map.delete(:__struct__)
    |> Map.delete(:__meta__)
  end
end

defmodule Access.Policies.UserPolicy do
  @moduledoc """
  Field-level access policy for the User schema. Sensitive fields like
  password hash, tax ID, and internal flags are only visible to admins
  or the account owner. Public profile fields are visible to all authenticated actors.
  """

  @public_fields [:id, :display_name, :bio, :avatar_url, :inserted_at]
  @owner_fields @public_fields ++ [:email, :phone, :notification_preferences]
  @admin_fields @owner_fields ++ [:password_hash, :tax_id, :internal_flags, :risk_score]

  @doc """
  Returns the list of field atoms that `actor` may read from the User schema.
  """
  @spec permitted_fields(map(), module()) :: [atom()]
  def permitted_fields(%{role: :admin}, MyApp.Accounts.User), do: @admin_fields
  def permitted_fields(%{role: :support}, MyApp.Accounts.User), do: @owner_fields

  def permitted_fields(%{id: actor_id}, MyApp.Accounts.User) do
    fn record ->
      if Map.get(record, :id) == actor_id, do: @owner_fields, else: @public_fields
    end
  end

  def permitted_fields(_actor, MyApp.Accounts.User), do: @public_fields
  def permitted_fields(_actor, _schema), do: []
end

defmodule Access.FieldGuard.Plug do
  @moduledoc """
  Stores the current actor on the conn so context modules can retrieve it
  for field-level filtering without accepting the actor as an explicit argument
  at every call site. Must be placed after authentication in the pipeline.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> conn
      user -> assign(conn, :field_guard_actor, user)
    end
  end

  @doc """
  Returns the actor stored for field-guard checks, or `nil`.
  """
  @spec actor(Plug.Conn.t()) :: map() | nil
  def actor(conn), do: conn.assigns[:field_guard_actor]
end
```
