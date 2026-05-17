```elixir
defmodule UserManagement.PermissionScopeParser do
  @moduledoc """
  Parses permission scope strings used in the role-based access control (RBAC) system.

  Scope strings are attached to API tokens and OAuth grants to express the
  level of access a client or user has been granted. They are evaluated by
  the policy engine on every authenticated request.

  Format:
    "<resource>:<action>:<ownership>"

  Resources:  orders, invoices, products, customers, reports, webhooks, users, teams
  Actions:    read, write, delete, admin
  Ownership:  own (only resources owned by the requesting user/org)
              any (all resources regardless of owner — elevated privilege)

  Examples:
    "orders:read:own"
    "invoices:write:any"
    "products:delete:own"
    "reports:read:any"
    "users:admin:any"
  """

  require Logger

  @known_resources  ~w(orders invoices products customers reports webhooks users teams)
  @known_actions    ~w(read write delete admin)
  @known_ownerships ~w(own any)

  @doc """
  Parses a scope string into a structured map.

  Returns `{:ok, %{resource: r, action: a, ownership: o}}` on success,
  or `{:error, reason}` when any component fails validation.
  """

  def parse_scope(raw) when is_binary(raw) do
    parts     = String.split(raw, ":")
    resource  = Enum.at(parts, 0)
    action    = Enum.at(parts, 1)
    ownership = Enum.at(parts, 2)

    with :ok <- validate_resource(resource),
         :ok <- validate_action(action),
         :ok <- validate_ownership(ownership) do
      {:ok, %{
        resource:  resource,
        action:    action,
        ownership: ownership,
        raw:       raw
      }}
    end
  end

  @doc """
  Parses a space-separated list of scope strings (as used in OAuth `scope` parameter).
  """
  def parse_scope_list(raw_scopes) when is_binary(raw_scopes) do
    raw_scopes
    |> String.split(" ", trim: true)
    |> Enum.map(&parse_scope/1)
    |> Enum.reduce({[], []}, fn
      {:ok, scope},     {ok, err} -> {[scope | ok], err}
      {:error, reason}, {ok, err} -> {ok, [{reason} | err]}
    end)
    |> then(fn {ok, err} -> %{ok: Enum.reverse(ok), error: Enum.reverse(err)} end)
  end

  @doc """
  Returns true when a set of parsed scopes grants the requested access.
  """
  def grants_access?(scopes, resource, action, ownership_context) when is_list(scopes) do
    Enum.any?(scopes, fn scope ->
      scope.resource == resource and
      scope.action   == action   and
      covers_ownership?(scope.ownership, ownership_context)
    end)
  end

  @doc """
  Returns true when a scope grants admin-level access to a resource.
  """
  def admin_scope?(%{action: "admin"}), do: true
  def admin_scope?(_), do: false

  @doc """
  Returns all scopes from a list that grant access to a specific resource.
  """
  def scopes_for_resource(scopes, resource) when is_list(scopes) and is_binary(resource) do
    Enum.filter(scopes, &(&1.resource == resource))
  end

  @doc """
  Serialises a scope map back to its string representation.
  """
  def to_string(%{resource: r, action: a, ownership: o}), do: "#{r}:#{a}:#{o}"

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_resource(r) when is_binary(r) do
    if r in @known_resources, do: :ok, else: {:error, {:unknown_resource, r}}
  end

  defp validate_resource(nil), do: {:error, :missing_resource}
  defp validate_resource(_),   do: {:error, :invalid_resource}

  defp validate_action(a) when is_binary(a) do
    if a in @known_actions, do: :ok, else: {:error, {:unknown_action, a}}
  end

  defp validate_action(nil), do: {:error, :missing_action}
  defp validate_action(_),   do: {:error, :invalid_action}

  defp validate_ownership(o) when is_binary(o) do
    if o in @known_ownerships, do: :ok, else: {:error, {:unknown_ownership, o}}
  end

  defp validate_ownership(nil), do: {:error, :missing_ownership}
  defp validate_ownership(_),   do: {:error, :invalid_ownership}

  defp covers_ownership?("any", _), do: true
  defp covers_ownership?("own", :own), do: true
  defp covers_ownership?(_, _), do: false
end
```
