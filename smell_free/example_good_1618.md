```elixir
defmodule Identity.Authentication do
  @moduledoc """
  Handles user credential verification and session token lifecycle.

  Password comparison uses constant-time functions. Tokens are signed JWTs
  with explicit expiry; the signing key is supplied per-call via config struct
  rather than read from global application environment.
  """

  alias Identity.Authentication.{Config, TokenClaims, CredentialStore}
  alias Identity.Accounts.User

  @token_ttl_seconds 3_600

  @type result(t) :: {:ok, t} | {:error, String.t()}

  @doc """
  Verifies credentials and returns a signed session token on success.
  """
  @spec authenticate(String.t(), String.t(), Config.t()) :: result(String.t())
  def authenticate(email, password, %Config{} = config)
      when is_binary(email) and is_binary(password) do
    with {:ok, user} <- CredentialStore.fetch_by_email(email),
         :ok <- verify_password(password, user.password_hash),
         {:ok, token} <- issue_token(user, config) do
      {:ok, token}
    end
  end

  def authenticate(_, _, _), do: {:error, "invalid credentials"}

  @doc """
  Verifies a session token and returns the embedded claims if valid and unexpired.
  """
  @spec verify_token(String.t(), Config.t()) :: result(TokenClaims.t())
  def verify_token(token, %Config{} = config) when is_binary(token) do
    with {:ok, raw_claims} <- Config.verify_jwt(config, token),
         {:ok, claims} <- TokenClaims.decode(raw_claims),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, "token invalid: #{reason}"}
    end
  end

  @doc """
  Rotates an existing valid token, extending its TTL from the current time.
  """
  @spec refresh_token(String.t(), Config.t()) :: result(String.t())
  def refresh_token(token, %Config{} = config) when is_binary(token) do
    with {:ok, claims} <- verify_token(token, config),
         {:ok, user} <- CredentialStore.fetch_by_id(claims.user_id),
         {:ok, new_token} <- issue_token(user, config) do
      {:ok, new_token}
    end
  end

  # --- private helpers ---

  defp verify_password(provided, hash) do
    if Bcrypt.verify_pass(provided, hash) do
      :ok
    else
      {:error, "invalid credentials"}
    end
  end

  defp issue_token(%User{id: id, email: email, role: role}, config) do
    expiry = System.system_time(:second) + @token_ttl_seconds

    claims = %{
      "sub" => id,
      "email" => email,
      "role" => Atom.to_string(role),
      "exp" => expiry,
      "iat" => System.system_time(:second)
    }

    Config.sign_jwt(config, claims)
  end

  defp check_expiry(%TokenClaims{exp: exp}) do
    if System.system_time(:second) < exp do
      :ok
    else
      {:error, "token expired"}
    end
  end
end

defmodule Identity.Authentication.TokenClaims do
  @moduledoc "Typed value object wrapping verified JWT claims."

  @enforce_keys [:user_id, :email, :role, :exp, :iat]
  defstruct [:user_id, :email, :role, :exp, :iat]

  @type t :: %__MODULE__{
          user_id: String.t(),
          email: String.t(),
          role: String.t(),
          exp: integer(),
          iat: integer()
        }

  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(%{"sub" => uid, "email" => email, "role" => role, "exp" => exp, "iat" => iat})
      when is_binary(uid) and is_binary(email) and is_binary(role) and
             is_integer(exp) and is_integer(iat) do
    {:ok, %__MODULE__{user_id: uid, email: email, role: role, exp: exp, iat: iat}}
  end

  def decode(_), do: {:error, "malformed token claims"}
end

defmodule Identity.Authentication.Config do
  @moduledoc "Signing and verification configuration for session tokens."

  @enforce_keys [:signing_key, :algorithm]
  defstruct [:signing_key, :algorithm]

  @type t :: %__MODULE__{
          signing_key: String.t(),
          algorithm: String.t()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(signing_key, opts \\ []) when is_binary(signing_key) do
    %__MODULE__{
      signing_key: signing_key,
      algorithm: Keyword.get(opts, :algorithm, "HS256")
    }
  end

  @spec sign_jwt(t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def sign_jwt(%__MODULE__{signing_key: key, algorithm: alg}, claims) do
    JOSE.JWT.sign(%JOSE.JWK{}, %{"alg" => alg}, claims)
    |> JOSE.JWS.compact()
    |> then(&{:ok, elem(&1, 1)})
  rescue
    _ -> {:error, "token signing failed"}
  end

  @spec verify_jwt(t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify_jwt(%__MODULE__{signing_key: key}, token) do
    case JOSE.JWT.verify_strict(%JOSE.JWK{}, ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _} -> {:ok, claims}
      _ -> {:error, "invalid signature"}
    end
  rescue
    _ -> {:error, "verification failed"}
  end
end
```
