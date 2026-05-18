# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `OAuth2Handler.extract_scopes/1`, line where `String.to_atom/1` converts scope strings |
| **Affected function(s)** | `OAuth2Handler.extract_scopes/1` |
| **Short explanation** | OAuth2 scopes arrive as a space-separated string from the authorization server's token introspection response. Splitting and converting each scope to an atom means any scope string—including custom, vendor-prefixed, or future scopes—will permanently occupy an atom slot on every token verification. |

```elixir
defmodule MyApp.Auth.OAuth2Handler do
  @moduledoc """
  Handles OAuth2 token verification, scope extraction, and authorization
  enforcement for protected API endpoints.
  """

  require Logger

  alias MyApp.Auth.{TokenCache, IntrospectionClient}

  @introspection_cache_ttl 300
  @required_issuer "https://auth.myapp.example.com"

  @doc """
  Verifies a Bearer token string and returns a decoded claims map.
  Caches introspection results to avoid repeated upstream calls.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(raw_token) when is_binary(raw_token) do
    cache_key = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

    case TokenCache.get(cache_key) do
      {:ok, cached} ->
        Logger.debug("Token resolved from cache")
        {:ok, cached}

      {:miss, _} ->
        with {:ok, claims} <- IntrospectionClient.introspect(raw_token),
             :ok <- validate_claims(claims),
             {:ok, enriched} <- enrich_claims(claims) do
          TokenCache.put(cache_key, enriched, ttl: @introspection_cache_ttl)
          {:ok, enriched}
        end
    end
  end

  @doc """
  Checks that the verified claims include all of the required scopes.
  """
  @spec authorize(map(), list(atom())) :: :ok | {:error, :insufficient_scope}
  def authorize(%{scopes: granted_scopes}, required_scopes) when is_list(required_scopes) do
    if Enum.all?(required_scopes, &(&1 in granted_scopes)) do
      :ok
    else
      missing = required_scopes -- granted_scopes
      Logger.warning("Authorization failed due to missing scopes", missing: missing)
      {:error, :insufficient_scope}
    end
  end

  defp validate_claims(%{"active" => true, "iss" => @required_issuer}), do: :ok
  defp validate_claims(%{"active" => false}), do: {:error, :token_inactive}
  defp validate_claims(%{"iss" => iss}), do: {:error, {:invalid_issuer, iss}}
  defp validate_claims(_), do: {:error, :malformed_claims}

  defp enrich_claims(%{"sub" => sub, "exp" => exp} = claims) do
    with {:ok, scopes} <- extract_scopes(claims) do
      enriched = %{
        subject: sub,
        expires_at: DateTime.from_unix!(exp),
        scopes: scopes,
        client_id: claims["client_id"],
        raw: claims
      }

      {:ok, enriched}
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to each
  # individual scope string obtained from the token introspection response. OAuth2
  # scopes are not a closed set: authorization servers can define arbitrary scopes
  # (e.g., "urn:example:read", "profile:extended", "api:v2:write"). Every unique
  # scope string seen at runtime becomes a permanent atom, and a system that handles
  # many different OAuth2 clients or that rotates scopes frequently will silently
  # exhaust the atom table. String comparisons on scope lists are equally effective
  # and entirely safe.
  defp extract_scopes(%{"scope" => scope_string}) when is_binary(scope_string) do
    scopes =
      scope_string
      |> String.split(" ", trim: true)
      |> Enum.map(&String.to_atom/1)

    {:ok, scopes}
  end
  # VALIDATION: SMELL END

  defp extract_scopes(%{"scope" => scopes}) when is_list(scopes) do
    {:ok, Enum.map(scopes, &String.to_atom/1)}
  end

  defp extract_scopes(_), do: {:ok, []}
end
```
