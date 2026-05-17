```elixir
defmodule Auth.TokenVerifier do
  @moduledoc """
  Verifies signed JWT tokens issued by the identity provider and extracts
  the user principal used for request authorization.
  """

  require Logger

  @valid_roles ~w(admin manager operator viewer)

  @doc """
  Verifies the given JWT string and returns `{:ok, principal}` on success
  or `{:error, reason}` on failure.
  """
  def verify(token) when is_binary(token) do
    with {:ok, claims} <- decode_and_verify(token),
         {:ok, _}      <- check_expiry(claims),
         {:ok, _}      <- check_issuer(claims) do
      principal = build_principal(claims)
      {:ok, principal}
    end
  end

  defp build_principal(claims) do
    %{
      user_id:    Map.fetch!(claims, "sub"),
      email:      Map.fetch!(claims, "email"),
      role:       extract_role(claims),
      tenant_id:  Map.fetch!(claims, "tenant_id"),
      issued_at:  Map.fetch!(claims, "iat")
    }
  end

  @doc """
  Extracts the user's role from the token claims map.
  Returns one of: `:admin`, `:manager`, `:operator`, `:viewer`.
  """

  def extract_role(claims) do
    role_string = Map.get(claims, "role", "")

    cond do
      role_string == "admin"    -> :admin
      role_string == "manager"  -> :manager
      role_string == "operator" -> :operator
      role_string == "viewer"   -> :viewer
      true                      -> :guest
    end
  end

  defp decode_and_verify(token) do
    case JOSE.JWT.verify_strict(jwks(), ["RS256"], token) do
      {true, %{fields: claims}, _} -> {:ok, claims}
      {false, _, _}                 -> {:error, :invalid_signature}
      _                             -> {:error, :malformed_token}
    end
  end

  defp check_expiry(%{"exp" => exp}) do
    now = System.system_time(:second)

    if exp > now do
      {:ok, :not_expired}
    else
      {:error, :token_expired}
    end
  end

  defp check_expiry(_claims), do: {:error, :missing_exp_claim}

  defp check_issuer(%{"iss" => iss}) do
    expected = Application.fetch_env!(:auth, :expected_issuer)

    if iss == expected do
      {:ok, :issuer_valid}
    else
      {:error, {:unexpected_issuer, iss}}
    end
  end

  defp check_issuer(_claims), do: {:error, :missing_iss_claim}

  defp jwks do
    Application.fetch_env!(:auth, :jwks)
  end
end
```
