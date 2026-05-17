```elixir
# ── file: lib/auth/token.ex ──────────────────────────────────────────────────


defmodule Auth.Token do
  @moduledoc """
  JWT generation, verification, and revocation for the authentication system.
  Defined in `lib/auth/token.ex`.
  """

  alias Auth.TokenStore
  alias Auth.KeyProvider

  @token_ttl_seconds 3_600
  @refresh_ttl_seconds 86_400 * 30
  @algorithm "HS256"

  @type claims :: %{
    required(:sub) => String.t(),
    required(:iat) => integer(),
    required(:exp) => integer(),
    optional(:roles) => [String.t()],
    optional(:jti) => String.t()
  }

  @doc """
  Generate a signed JWT for the given subject with optional extra claims.
  Returns `{:ok, token_string}` or `{:error, reason}`.
  """
  @spec generate(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def generate(subject, extra_claims \\ %{}) do
    now = System.system_time(:second)
    jti = generate_jti()

    claims =
      extra_claims
      |> Map.merge(%{
        sub: subject,
        iat: now,
        exp: now + @token_ttl_seconds,
        jti: jti
      })

    with {:ok, secret} <- KeyProvider.signing_secret(),
         {:ok, token} <- sign(claims, secret) do
      :ok = TokenStore.register(jti, subject, now + @token_ttl_seconds)
      {:ok, token}
    end
  end

  @doc "Verify a JWT string and return its decoded claims."
  @spec verify(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify(token_string) do
    with {:ok, secret} <- KeyProvider.signing_secret(),
         {:ok, claims} <- decode_and_verify(token_string, secret),
         :ok <- check_expiry(claims),
         :ok <- check_revoked(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Revoke a token by its JTI, preventing future use."
  @spec revoke(String.t()) :: :ok | {:error, String.t()}
  def revoke(jti) when is_binary(jti) do
    case TokenStore.revoke(jti) do
      :ok -> :ok
      :not_found -> {:error, "Token JTI not found: #{jti}"}
    end
  end

  @doc "Exchange a valid token for a new one with a reset TTL."
  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def refresh(token_string) do
    with {:ok, claims} <- verify(token_string),
         :ok <- revoke(claims.jti) do
      generate(claims.sub, Map.drop(claims, [:sub, :iat, :exp, :jti]))
    end
  end

  defp sign(claims, secret) do
    Jason.encode(claims)
    |> case do
      {:ok, payload} ->
        sig = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
        header = Base.url_encode64(~s({"alg":"#{@algorithm}","typ":"JWT"}), padding: false)
        body = Base.url_encode64(payload, padding: false)
        {:ok, "#{header}.#{body}.#{sig}"}

      {:error, _} = err ->
        err
    end
  end

  defp decode_and_verify(token, secret) do
    parts = String.split(token, ".")

    case parts do
      [_header, body, sig] ->
        expected_sig =
          :crypto.mac(:hmac, :sha256, secret, Base.url_decode64!(body, padding: false))
          |> Base.url_encode64(padding: false)

        if Plug.Crypto.secure_compare(sig, expected_sig) do
          body |> Base.url_decode64!(padding: false) |> Jason.decode(keys: :atoms)
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp check_expiry(%{exp: exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :token_expired}
  end

  defp check_revoked(%{jti: jti}) do
    if TokenStore.revoked?(jti), do: {:error, :token_revoked}, else: :ok
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/auth/token_claims.ex ─────────────────────────────────────────────────────


defmodule Auth.Token do
  @moduledoc """
  Helper utilities for inspecting and extracting claims from Auth tokens.
  """

  @doc "Extract the subject (user ID) from a decoded claims map."
  @spec subject(map()) :: {:ok, String.t()} | {:error, String.t()}
  def subject(%{sub: sub}) when is_binary(sub) and sub != "", do: {:ok, sub}
  def subject(_), do: {:error, "Missing or invalid subject claim"}

  @doc "Return the list of roles embedded in the token claims."
  @spec roles(map()) :: [String.t()]
  def roles(%{roles: roles}) when is_list(roles), do: roles
  def roles(_), do: []

  @doc "Check whether the token claims grant a specific role."
  @spec has_role?(map(), String.t()) :: boolean()
  def has_role?(claims, role), do: role in roles(claims)

  @doc "Return remaining TTL in seconds for a claims map."
  @spec remaining_ttl(map()) :: integer()
  def remaining_ttl(%{exp: exp}) do
    max(exp - System.system_time(:second), 0)
  end

  def remaining_ttl(_), do: 0

  @doc "Fetch all claims associated with a subject from the token store."
  @spec claims_for(String.t()) :: {:ok, map()} | {:error, String.t()}
  def claims_for(subject) when is_binary(subject) do
    case Auth.TokenStore.lookup_by_subject(subject) do
      {:ok, record} ->
        {:ok,
         %{
           sub: record.subject,
           jti: record.jti,
           exp: record.expires_at,
           issued_at: record.created_at
         }}

      :not_found ->
        {:error, "No active token found for subject: #{subject}"}
    end
  end
end

```
