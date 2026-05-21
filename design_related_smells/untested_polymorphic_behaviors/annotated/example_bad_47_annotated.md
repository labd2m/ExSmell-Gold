## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `all_scopes_allowed?/2` — the `Enum.all?(requested_scopes, ...)` call
- **Affected function(s):** `Auth.ScopeValidator.all_scopes_allowed?/2`
- **Short explanation:** `Enum.all?/2` uses the `Enumerable` protocol on `requested_scopes`. No guard clause restricts it to types implementing `Enumerable`. Passing an atom, string, integer, or any non-Enumerable value crashes with `Protocol.UndefinedError`. The function's polymorphic dependency is entirely implicit.

```elixir
defmodule Auth.ScopeValidator do
  @moduledoc """
  Validates OAuth2 scope assignments for API tokens and authorization requests.
  Used by the token issuance pipeline and API gateway middleware.
  """

  alias Auth.{TokenClaims, ScopeRegistry, AuditLog}

  @public_scopes ~w(profile:read openid)
  @admin_scopes ~w(admin:write admin:delete system:config)
  @elevated_scopes @admin_scopes ++ ~w(billing:write users:delete)

  def validate_token_scopes(%TokenClaims{} = claims, required_scopes) do
    granted = MapSet.new(claims.scopes)

    missing =
      required_scopes
      |> Enum.reject(fn scope -> MapSet.member?(granted, scope) end)

    if missing == [] do
      :ok
    else
      {:error, {:insufficient_scopes, missing}}
    end
  end

  def issue_token_scopes(requested_scopes, %{role: role, client_id: client_id}) do
    with :ok <- validate_scope_format(requested_scopes),
         {:ok, allowed} <- ScopeRegistry.allowed_for_role(role, client_id) do
      if all_scopes_allowed?(requested_scopes, allowed) do
        {:ok, requested_scopes}
      else
        denied = Enum.reject(requested_scopes, &(&1 in allowed))
        {:error, {:scopes_not_permitted, denied}}
      end
    end
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `Enum.all?/2` uses the `Enumerable` protocol on
  # VALIDATION: `requested_scopes`. No guard clause restricts `requested_scopes` to types
  # VALIDATION: that implement `Enumerable` (e.g., list, MapSet, map, range).
  # VALIDATION: Passing a binary string like "profile:read", an atom like :admin, an
  # VALIDATION: integer, or a PID raises `Protocol.UndefinedError` at runtime. Because
  # VALIDATION: the function is called inside a `with` pipeline, the crash is hard to
  # VALIDATION: trace back to this specific argument without careful inspection.
  def all_scopes_allowed?(requested_scopes, allowed_scopes) do
    allowed_set = MapSet.new(allowed_scopes)
    Enum.all?(requested_scopes, &MapSet.member?(allowed_set, &1))
  end
  # VALIDATION: SMELL END

  def validate_scope_format(scopes) when is_list(scopes) do
    invalid =
      Enum.reject(scopes, fn scope ->
        is_binary(scope) and String.match?(scope, ~r/^[a-z_]+:[a-z_]+$/)
      end)

    if invalid == [] do
      :ok
    else
      {:error, {:malformed_scopes, invalid}}
    end
  end

  def validate_scope_format(_), do: {:error, :scopes_must_be_list}

  def contains_elevated_scopes?(scopes) when is_list(scopes) do
    Enum.any?(scopes, &(&1 in @elevated_scopes))
  end

  def contains_admin_scopes?(scopes) when is_list(scopes) do
    Enum.any?(scopes, &(&1 in @admin_scopes))
  end

  def public_only?(scopes) when is_list(scopes) do
    Enum.all?(scopes, &(&1 in @public_scopes))
  end

  def scope_summary(scopes) when is_list(scopes) do
    %{
      total: length(scopes),
      public: Enum.count(scopes, &(&1 in @public_scopes)),
      elevated: Enum.count(scopes, &(&1 in @elevated_scopes)),
      admin: Enum.count(scopes, &(&1 in @admin_scopes)),
      custom: Enum.count(scopes, &(&1 not in @public_scopes ++ @elevated_scopes))
    }
  end

  def log_scope_grant(user_id, client_id, scopes) do
    AuditLog.write(%{
      event: :scope_granted,
      user_id: user_id,
      client_id: client_id,
      scopes: scopes,
      timestamp: DateTime.utc_now()
    })
  end
end
```
