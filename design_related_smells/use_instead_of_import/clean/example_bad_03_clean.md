```elixir
defmodule Auth.CryptoUtils do
  @moduledoc """
  Low-level cryptographic helpers used within the authentication subsystem.
  """

  @signing_secret Application.compile_env(:my_app, [:auth, :signing_secret], "dev_secret_key")

  def hmac_sign(payload) when is_binary(payload) do
    :crypto.mac(:hmac, :sha256, @signing_secret, payload)
    |> Base.url_encode64(padding: false)
  end

  def hmac_verify(payload, signature) when is_binary(payload) and is_binary(signature) do
    expected = hmac_sign(payload)
    Plug.Crypto.secure_compare(expected, signature)
  end

  def random_token(byte_length \\ 32) do
    :crypto.strong_rand_bytes(byte_length)
    |> Base.url_encode64(padding: false)
  end
end

defmodule Auth.TokenHelpers do
  @moduledoc """
  Session token construction and validation helpers, shared via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Auth.CryptoUtils  # propagates crypto dependency into every caller

      def build_token(user_id, role, ttl_seconds \\ 3600) do
        expires_at = System.system_time(:second) + ttl_seconds

        payload =
          %{user_id: user_id, role: role, expires_at: expires_at}
          |> Jason.encode!()
          |> Base.url_encode64(padding: false)

        signature = hmac_sign(payload)
        "#{payload}.#{signature}"
      end

      def decode_token(token) do
        with [payload_b64, signature] <- String.split(token, ".", parts: 2),
             true <- hmac_verify(payload_b64, signature),
             {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, claims} <- Jason.decode(json, keys: :atoms) do
          {:ok, claims}
        else
          _ -> {:error, :invalid_token}
        end
      end

      def token_expired?(%{expires_at: exp}), do: System.system_time(:second) > exp
    end
  end
end

defmodule Auth.SessionManager do
  @moduledoc """
  Manages user sessions: creation, refresh, revocation, and introspection.
  Integrates with the token subsystem and stores active sessions in-memory
  (or a backing store in production via the configured adapter).
  """

  use Auth.TokenHelpers

  @session_ttl 3_600
  @refresh_window 300

  def create(user_id, role) do
    token = build_token(user_id, role, @session_ttl)

    session = %{
      id:         session_id(),
      user_id:    user_id,
      role:       role,
      token:      token,
      created_at: System.system_time(:second),
      last_seen:  System.system_time(:second),
      revoked:    false
    }

    {:ok, session}
  end

  def validate(token) do
    with {:ok, claims} <- decode_token(token),
         false         <- token_expired?(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
      true             -> {:error, :token_expired}
    end
  end

  def refresh(%{token: token, revoked: false} = session) do
    with {:ok, claims}  <- decode_token(token),
         true           <- nearly_expired?(claims) do
      new_token = build_token(claims.user_id, claims.role, @session_ttl)
      {:ok, %{session | token: new_token, last_seen: System.system_time(:second)}}
    else
      false            -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh(%{revoked: true}), do: {:error, :session_revoked}

  def revoke(session), do: {:ok, %{session | revoked: true}}

  def active?(%{revoked: true}), do: false

  def active?(%{token: token}) do
    case decode_token(token) do
      {:ok, claims} -> not token_expired?(claims)
      _             -> false
    end
  end

  def touch(session), do: {:ok, %{session | last_seen: System.system_time(:second)}}

  defp nearly_expired?(%{expires_at: exp}) do
    remaining = exp - System.system_time(:second)
    remaining > 0 and remaining <= @refresh_window
  end

  defp session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
