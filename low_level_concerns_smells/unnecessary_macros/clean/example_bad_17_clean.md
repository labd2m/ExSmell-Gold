```elixir
defmodule Auth.ClaimsUtils do
  @moduledoc """
  Helpers for reading and validating JWT claim maps after successful
  token verification in the authentication pipeline.
  """

  defmacro fetch_required(claims, key) do
    quote do
      case Map.fetch(unquote(claims), unquote(key)) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "Required claim '#{unquote(key)}' is missing"
      end
    end
  end

  @doc """
  Returns the list of scopes from a claims map, defaulting to an empty list.
  """
  @spec scopes(map()) :: list(String.t())
  def scopes(claims) do
    case Map.fetch(claims, "scope") do
      {:ok, scope_string} when is_binary(scope_string) -> String.split(scope_string, " ")
      {:ok, scopes} when is_list(scopes) -> scopes
      _ -> []
    end
  end

  @doc """
  Returns whether the token has not yet expired.
  """
  @spec valid_expiry?(map()) :: boolean()
  def valid_expiry?(%{"exp" => exp}) when is_integer(exp) do
    System.os_time(:second) < exp
  end

  def valid_expiry?(_), do: false

  @doc """
  Checks whether the given scope is present in the claims.
  """
  @spec has_scope?(map(), String.t()) :: boolean()
  def has_scope?(claims, required_scope) do
    required_scope in scopes(claims)
  end
end

defmodule Auth.TokenVerifier do
  @moduledoc """
  Verifies JWTs and extracts validated identity information for use
  in downstream plug pipelines and controller actions.
  """

  require Auth.ClaimsUtils

  alias Auth.ClaimsUtils

  @doc """
  Extracts the subject identifier from verified JWT claims.
  Raises `ArgumentError` if the `sub` claim is absent.
  """
  @spec subject!(map()) :: String.t()
  def subject!(claims) do
    ClaimsUtils.fetch_required(claims, "sub")
  end

  @doc """
  Extracts the tenant identifier from verified JWT claims.
  Raises `ArgumentError` if the `tenant_id` claim is absent.
  """
  @spec tenant_id!(map()) :: String.t()
  def tenant_id!(claims) do
    ClaimsUtils.fetch_required(claims, "tenant_id")
  end

  @doc """
  Extracts the issuer from verified JWT claims.
  """
  @spec issuer!(map()) :: String.t()
  def issuer!(claims) do
    ClaimsUtils.fetch_required(claims, "iss")
  end

  @doc """
  Builds a principal map from raw verified claims.
  Raises if required claims are missing or token is expired.
  """
  @spec build_principal(map()) :: {:ok, map()} | {:error, String.t()}
  def build_principal(claims) do
    if not ClaimsUtils.valid_expiry?(claims) do
      {:error, "Token has expired"}
    else
      {:ok,
       %{
         subject: subject!(claims),
         tenant_id: tenant_id!(claims),
         issuer: issuer!(claims),
         scopes: ClaimsUtils.scopes(claims),
         authenticated_at: DateTime.utc_now()
       }}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  @doc """
  Returns true if the principal has all of the specified scopes.
  """
  @spec authorised?(map(), list(String.t())) :: boolean()
  def authorised?(%{scopes: scopes}, required_scopes) do
    Enum.all?(required_scopes, &(&1 in scopes))
  end

  @doc """
  Returns the tenant-scoped resource prefix string for a principal.
  """
  @spec resource_prefix(map()) :: String.t()
  def resource_prefix(%{tenant_id: tid, subject: sub}) do
    "tenants/#{tid}/users/#{sub}"
  end
end
```
