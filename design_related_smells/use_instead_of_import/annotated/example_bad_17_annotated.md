# Annotated Bad Example 17

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Auth.SessionManager`, `use Auth.JWTHelpers` directive
**Affected Functions:** `create_session/2`, `validate_session/1`, `refresh_session/1`, `revoke_session/1`
**Explanation:** `Auth.SessionManager` depends on `Auth.JWTHelpers` only for token-encoding and decoding utilities. However, the `use` directive expands `__using__/1`, which silently injects an alias for `Auth.TokenBlacklist`, a dependency the client module did not explicitly declare. It also injects the `@token_expiry_seconds` and `@issuer` module attributes. A reader of `SessionManager` has no indication that `TokenBlacklist` is available unless they inspect the library's macro. A plain `import Auth.JWTHelpers` would expose only the needed functions without the hidden alias propagation.

```elixir
defmodule Auth.JWTHelpers do
  @moduledoc """
  Low-level helpers for encoding, decoding, and verifying JWT tokens.
  Does not handle persistence or blacklisting directly.
  """

  @secret_key Application.compile_env(:my_app, [:jwt, :secret], "default_dev_secret")

  def encode_token(claims) when is_map(claims) do
    payload =
      claims
      |> Map.put("iat", System.system_time(:second))
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
    sig    = sign("#{header}.#{payload}")
    "#{header}.#{payload}.#{sig}"
  end

  def decode_token(token) when is_binary(token) do
    case String.split(token, ".") do
      [header, payload, sig] ->
        if sig == sign("#{header}.#{payload}") do
          decoded = Base.url_decode64!(payload, padding: false)
          {:ok, Jason.decode!(decoded)}
        else
          {:error, :invalid_signature}
        end
      _ ->
        {:error, :malformed_token}
    end
  end

  def token_expired?(claims) do
    exp = Map.get(claims, "exp", 0)
    System.system_time(:second) >= exp
  end

  def build_claims(user_id, role, expiry_seconds) do
    now = System.system_time(:second)
    %{
      "sub"  => to_string(user_id),
      "role" => to_string(role),
      "iat"  => now,
      "exp"  => now + expiry_seconds
    }
  end

  defp sign(data) do
    :crypto.mac(:hmac, :sha256, @secret_key, data)
    |> Base.url_encode64(padding: false)
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 secretly injects an alias
  # for Auth.TokenBlacklist and two module attributes into every module that
  # calls `use Auth.JWTHelpers`. The client module never explicitly declared
  # a dependency on TokenBlacklist; that dependency is invisible without
  # inspecting this macro.
  defmacro __using__(_opts) do
    quote do
      import Auth.JWTHelpers
      alias Auth.TokenBlacklist

      @token_expiry_seconds 3_600
      @issuer               "my_app"
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Auth.TokenBlacklist do
  @moduledoc "In-memory blacklist for revoked JWT tokens (stub)."

  def revoked?(jti), do: false
  def revoke(jti),   do: :ok
end

defmodule Auth.SessionManager do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Auth.JWTHelpers` causes __using__/1
  # to inject an alias to Auth.TokenBlacklist and two module attributes that
  # SessionManager never explicitly declared. A plain `import Auth.JWTHelpers`
  # would expose only the JWT utility functions that this module actually needs.
  use Auth.JWTHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Manages user sessions: creation, validation, refresh, and revocation.
  Tokens are signed JWTs and tracked through a blacklist for revocation support.
  """

  def create_session(user_id, role) do
    claims = build_claims(user_id, role, @token_expiry_seconds)
    token  = encode_token(claims)
    {:ok, %{token: token, expires_in: @token_expiry_seconds, user_id: user_id, role: role}}
  end

  def validate_session(token) when is_binary(token) do
    with {:ok, claims} <- decode_token(token),
         false         <- token_expired?(claims),
         jti           = Map.get(claims, "jti", token),
         false         <- TokenBlacklist.revoked?(jti) do
      {:ok, claims}
    else
      true             -> {:error, :token_expired}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_session(old_token) do
    with {:ok, claims} <- decode_token(old_token),
         false         <- token_expired?(claims) do
      user_id = claims["sub"]
      role    = claims["role"]
      jti     = Map.get(claims, "jti", old_token)
      TokenBlacklist.revoke(jti)
      create_session(user_id, role)
    else
      true  -> {:error, :token_expired}
      error -> error
    end
  end

  def revoke_session(token) when is_binary(token) do
    case decode_token(token) do
      {:ok, claims} ->
        jti = Map.get(claims, "jti", token)
        TokenBlacklist.revoke(jti)
        :ok
      {:error, _} = err ->
        err
    end
  end

  def session_info(token) do
    case validate_session(token) do
      {:ok, claims} ->
        {:ok, %{
          user_id:    claims["sub"],
          role:       claims["role"],
          issued_at:  claims["iat"],
          expires_at: claims["exp"]
        }}
      {:error, _} = err ->
        err
    end
  end
end
```
