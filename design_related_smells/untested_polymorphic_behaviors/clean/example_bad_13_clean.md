```elixir
defmodule Auth.TokenClaims do
  @moduledoc """
  Builds and validates JWT claims for the authentication system.
  Supports access tokens, refresh tokens, and short-lived password-reset tokens.
  """

  @issuer "myapp.example.com"
  @access_token_ttl 3_600
  @refresh_token_ttl 2_592_000
  @reset_token_ttl 900

  @doc """
  Constructs the base claims map for a new JWT.
  """
  def base_claims(token_type) when token_type in [:access, :refresh, :reset] do
    now = System.system_time(:second)

    ttl =
      case token_type do
        :access -> @access_token_ttl
        :refresh -> @refresh_token_ttl
        :reset -> @reset_token_ttl
      end

    %{
      "iss" => @issuer,
      "iat" => now,
      "exp" => now + ttl,
      "jti" => generate_jti()
    }
  end

  @doc """
  Builds the `sub` (subject) claim string from a user identifier.
  The subject uniquely identifies the principal of the token.
  """

  def build_subject_claim(subject) do
    "user:" <> to_string(subject)
  end

  @doc """
  Merges subject and role claims into a base claims map.
  """
  def put_identity_claims(claims, subject, roles)
      when is_map(claims) and is_binary(subject) and is_list(roles) do
    claims
    |> Map.put("sub", build_subject_claim(subject))
    |> Map.put("roles", Enum.map(roles, &Atom.to_string/1))
  end

  @doc """
  Adds an optional tenant scope to an existing claims map.
  """
  def put_tenant_claim(claims, tenant_id)
      when is_map(claims) and is_binary(tenant_id) do
    Map.put(claims, "tenant", tenant_id)
  end

  @doc """
  Validates the expiry of a decoded claims map.
  Returns `:ok` or `{:error, :token_expired}`.
  """
  def validate_expiry(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)

    if now <= exp do
      :ok
    else
      {:error, :token_expired}
    end
  end

  def validate_expiry(_), do: {:error, :missing_exp_claim}

  @doc """
  Validates that the issuer claim matches the expected issuer.
  """
  def validate_issuer(%{"iss" => iss}) when is_binary(iss) do
    if iss == @issuer do
      :ok
    else
      {:error, {:invalid_issuer, iss}}
    end
  end

  def validate_issuer(_), do: {:error, :missing_iss_claim}

  @doc """
  Runs all standard validations on decoded claims.
  Returns `:ok` or the first encountered error.
  """
  def validate_claims(claims) when is_map(claims) do
    with :ok <- validate_expiry(claims),
         :ok <- validate_issuer(claims) do
      :ok
    end
  end

  @doc """
  Returns the user ID portion of a `sub` claim string.
  """
  def extract_user_id("user:" <> user_id), do: {:ok, user_id}
  def extract_user_id(_), do: {:error, :invalid_subject}

  # --- Private ---

  defp generate_jti do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
```
