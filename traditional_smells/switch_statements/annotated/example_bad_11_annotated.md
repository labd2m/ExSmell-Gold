# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `TokenService` module — functions `token_ttl_seconds/1`, `token_scope/1`, and `revocation_strategy/1`
- **Affected functions:** `token_ttl_seconds/1`, `token_scope/1`, `revocation_strategy/1`
- **Short explanation:** The same `case token_type` branching over `:access`, `:refresh`, `:api_key`, and `:password_reset` is duplicated across three functions. Introducing a new token type requires editing all three case blocks, which is the Switch Statements smell.

---

```elixir
defmodule TokenService do
  @moduledoc """
  Issues, validates, and revokes authentication tokens for the platform's
  identity layer. Supports multiple token types with different TTLs, scopes,
  and revocation strategies.
  """

  require Logger

  @token_types [:access, :refresh, :api_key, :password_reset]

  def valid_token_types, do: @token_types

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over token_type
  # (:access, :refresh, :api_key, :password_reset) is duplicated in
  # token_ttl_seconds/1, token_scope/1, and revocation_strategy/1. Adding a new
  # token type requires updating all three case blocks independently.

  @doc """
  Returns the time-to-live in seconds for the given token type.
  """
  def token_ttl_seconds(%{token_type: token_type}) do
    case token_type do
      :access -> 900
      :refresh -> 2_592_000
      :api_key -> :infinity
      :password_reset -> 3_600
      _ -> 900
    end
  end

  @doc """
  Returns the list of permission scopes attached to tokens of this type.
  """
  def token_scope(%{token_type: token_type}) do
    case token_type do
      :access -> [:read, :write]
      :refresh -> [:token_refresh]
      :api_key -> [:read, :write, :admin]
      :password_reset -> [:password_write]
      _ -> [:read]
    end
  end

  @doc """
  Returns the revocation strategy for the token type.
  `:blocklist` means the token ID must be recorded in a deny-list.
  `:delete` means the token record must be removed from the store.
  `:noop` means tokens are stateless and cannot be revoked early.
  """
  def revocation_strategy(%{token_type: token_type}) do
    case token_type do
      :access -> :blocklist
      :refresh -> :delete
      :api_key -> :delete
      :password_reset -> :delete
      _ -> :blocklist
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Issues a new token for the given user, signing it with the application secret.
  """
  def issue(%{id: user_id}, token_type) when token_type in @token_types do
    now = DateTime.utc_now()
    jti = generate_jti()

    ttl = token_ttl_seconds(%{token_type: token_type})
    scopes = token_scope(%{token_type: token_type})

    expires_at =
      case ttl do
        :infinity -> nil
        seconds -> DateTime.add(now, seconds, :second)
      end

    payload = %{
      sub: user_id,
      jti: jti,
      token_type: token_type,
      scopes: scopes,
      iat: DateTime.to_unix(now),
      exp: if(expires_at, do: DateTime.to_unix(expires_at), else: nil)
    }

    {:ok, %{token: sign_payload(payload), jti: jti, expires_at: expires_at, scopes: scopes}}
  end

  def issue(_, token_type), do: {:error, {:unknown_token_type, token_type}}

  @doc """
  Validates a token string, returning the decoded claims or an error.
  """
  def validate(token_string) do
    with {:ok, claims} <- decode_and_verify(token_string),
         :ok <- check_expiry(claims),
         :ok <- check_blocklist(claims["jti"]) do
      {:ok, claims}
    end
  end

  @doc """
  Revokes a token according to the strategy for its type.
  """
  def revoke(%{jti: jti, token_type: token_type} = token) do
    strategy = revocation_strategy(%{token_type: token_type})

    case strategy do
      :blocklist ->
        Logger.info("Adding token #{jti} to blocklist.")
        add_to_blocklist(jti)

      :delete ->
        Logger.info("Deleting token #{jti} from store.")
        delete_token_record(jti)

      :noop ->
        Logger.debug("Token #{jti} is stateless; revocation not required.")
        {:ok, :noop}
    end

    {:ok, token}
  end

  # ---- Private helpers ----

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp sign_payload(payload) do
    Base.encode64(:erlang.term_to_binary(payload), padding: false)
  end

  defp decode_and_verify(token) do
    case Base.decode64(token, padding: false) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin, [:safe])}
      :error -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :malformed_token}
  end

  defp check_expiry(%{"exp" => nil}), do: :ok

  defp check_expiry(%{"exp" => exp}) do
    if DateTime.to_unix(DateTime.utc_now()) < exp, do: :ok, else: {:error, :token_expired}
  end

  defp check_expiry(_), do: {:error, :missing_expiry}

  defp check_blocklist(_jti), do: :ok
  defp add_to_blocklist(_jti), do: :ok
  defp delete_token_record(_jti), do: :ok
end
```
