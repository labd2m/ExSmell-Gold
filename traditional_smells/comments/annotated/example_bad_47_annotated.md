# Annotated Example — Code Smell: Comments

- **Smell name:** Comments
- **Expected smell location:** `MyApp.Auth.TokenManager` module, functions `issue_token/2` and `verify_token/1`
- **Affected function(s):** `issue_token/2`, `verify_token/1`, `revoke_token/1`
- **Short explanation:** The public API of this module is documented exclusively through block-style `#` comments placed directly above each function. None of these use `@doc`, meaning the documentation is stripped away at compile time (for documentation purposes), invisible to `IEx.Helpers.h/1`, and not picked up by ExDoc. In Elixir, `@doc` is the idiomatic and tooling-integrated way to document public functions.

```elixir
defmodule MyApp.Auth.TokenManager do
  @moduledoc false

  alias MyApp.Accounts.User
  alias MyApp.Repo
  alias MyApp.Auth.TokenStore

  @token_ttl_seconds 3_600
  @refresh_ttl_seconds 7 * 86_400
  @token_byte_length 32

  # -------------------------------------------------------------------
  # Issues a new access/refresh token pair for the given user.
  # `user` must be a %User{} struct with a valid :id field.
  # `opts` is a keyword list supporting:
  #   - :ttl (integer, seconds) — overrides the default access token TTL
  #   - :device_id (string) — associates the token with a specific device
  # Returns {:ok, %{access_token: token, refresh_token: token, expires_at: dt}}
  # or {:error, reason} if the user is suspended or token creation fails.
  # -------------------------------------------------------------------
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `issue_token/2` is fully documented
  # VALIDATION: using `#` comment blocks instead of `@doc`. These comments
  # VALIDATION: cannot be accessed via `h MyApp.Auth.TokenManager.issue_token/2`
  # VALIDATION: in IEx and are not rendered by ExDoc.
  def issue_token(%User{id: user_id, status: status}, opts \\ []) do
    # VALIDATION: SMELL END
    if status == :suspended do
      {:error, :account_suspended}
    else
      ttl = Keyword.get(opts, :ttl, @token_ttl_seconds)
      device_id = Keyword.get(opts, :device_id)

      access_token = generate_token()
      refresh_token = generate_token()
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      entry = %{
        user_id: user_id,
        access_token: hash_token(access_token),
        refresh_token: hash_token(refresh_token),
        device_id: device_id,
        expires_at: expires_at,
        revoked: false
      }

      case TokenStore.insert(entry) do
        {:ok, _} ->
          {:ok, %{access_token: access_token, refresh_token: refresh_token, expires_at: expires_at}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -------------------------------------------------------------------
  # Verifies an access token and returns the associated user_id.
  # The token string should be the raw (un-hashed) token returned by
  # issue_token/2. Checks expiry and revocation status.
  # Returns {:ok, user_id} on a valid, non-expired token,
  # or {:error, :invalid_token | :expired | :revoked}.
  # -------------------------------------------------------------------
  def verify_token(raw_token) when is_binary(raw_token) do
    hashed = hash_token(raw_token)

    case TokenStore.find_by_access_token(hashed) do
      nil ->
        {:error, :invalid_token}

      %{revoked: true} ->
        {:error, :revoked}

      %{expires_at: exp, user_id: uid} ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt do
          {:ok, uid}
        else
          {:error, :expired}
        end
    end
  end

  # -------------------------------------------------------------------
  # Revokes a token so it can no longer be used for authentication.
  # Accepts either the raw access_token string or a token store record id.
  # Returns :ok if the revocation succeeded, {:error, :not_found} otherwise.
  # -------------------------------------------------------------------
  def revoke_token(raw_token) when is_binary(raw_token) do
    hashed = hash_token(raw_token)

    case TokenStore.find_by_access_token(hashed) do
      nil -> {:error, :not_found}
      record -> TokenStore.revoke(record.id)
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_byte_length) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
```
