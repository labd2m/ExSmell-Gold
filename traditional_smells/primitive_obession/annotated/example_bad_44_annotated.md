# Annotated Example — Primitive Obsession

## Metadata

- **Smell name:** Primitive Obsession
- **Expected smell location:** `Auth.TokenManager` module — `token_string`, `scope`, `expires_in_seconds`, and `issued_at_unix` are raw primitives throughout `issue_token/4`, `verify_token/2`, and `revoke_token/2` instead of a `Token` struct
- **Affected functions:** `issue_token/4`, `verify_token/2`, `revoke_token/2`, `token_ttl_remaining/1`
- **Short explanation:** An authentication token is a rich domain concept encompassing a raw string value, a scope, an expiry timestamp, and an issuer — yet every function represents it as a loose collection of primitives (`string`, `integer`, `string`). A `Token` struct would group these cohesively, enable pattern matching, and prevent callers from accidentally passing, for example, an expiry integer where a scope string is expected.

---

```elixir
defmodule Auth.TokenManager do
  @moduledoc """
  Issues, verifies, and revokes short-lived access tokens for the
  platform's authentication subsystem.
  """

  require Logger

  @token_store :token_ets_store
  @default_ttl_seconds 3_600
  @max_ttl_seconds 86_400

  @valid_scopes ["read", "write", "admin", "readonly", "service"]

  def init do
    :ets.new(@token_store, [:named_table, :public, read_concurrency: true])
    :ok
  end

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because an access token is a cohesive domain
  # object (raw value + scope + expiry + subject), yet it is represented as four
  # separate primitives: `subject` (string), `scope` (string), `ttl_seconds`
  # (integer), and the returned `token_string` (string). Callers must manually
  # track and pass each piece; there is no `Token` struct to enforce the contract
  # or carry all fields together. This also means `verify_token/2` receives a
  # raw string and a raw string scope rather than a proper `Token` value object.
  @spec issue_token(String.t(), String.t(), integer(), String.t()) ::
          {:ok, String.t(), integer()} | {:error, String.t()}
  def issue_token(subject, scope, ttl_seconds, issuer)
      when is_binary(subject) and is_binary(scope) and
             is_integer(ttl_seconds) and is_binary(issuer) do
    with :ok <- validate_scope(scope),
         :ok <- validate_ttl(ttl_seconds) do
      token_string = generate_token_string()
      issued_at_unix = System.system_time(:second)
      expires_at_unix = issued_at_unix + ttl_seconds

      record = %{
        token: token_string,
        subject: subject,
        scope: scope,
        issuer: issuer,
        issued_at: issued_at_unix,
        expires_at: expires_at_unix,
        revoked: false
      }

      :ets.insert(@token_store, {token_string, record})
      Logger.info("Issued token for subject=#{subject} scope=#{scope} ttl=#{ttl_seconds}s")
      {:ok, token_string, expires_at_unix}
    end
  end

  def issue_token(_, _, _, _), do: {:error, "invalid_arguments"}

  @spec verify_token(String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def verify_token(token_string, required_scope)
      when is_binary(token_string) and is_binary(required_scope) do
    now = System.system_time(:second)

    case :ets.lookup(@token_store, token_string) do
      [{^token_string, record}] ->
        cond do
          record.revoked ->
            {:error, "token_revoked"}

          record.expires_at <= now ->
            {:error, "token_expired"}

          record.scope != required_scope and record.scope != "admin" ->
            {:error, "insufficient_scope"}

          true ->
            {:ok, record}
        end

      [] ->
        {:error, "token_not_found"}
    end
  end

  @spec revoke_token(String.t(), String.t()) :: :ok | {:error, String.t()}
  def revoke_token(token_string, revoked_by)
      when is_binary(token_string) and is_binary(revoked_by) do
    case :ets.lookup(@token_store, token_string) do
      [{^token_string, record}] ->
        updated = Map.merge(record, %{revoked: true, revoked_by: revoked_by})
        :ets.insert(@token_store, {token_string, updated})
        Logger.warning("Token revoked by #{revoked_by}: #{String.slice(token_string, 0, 8)}…")
        :ok

      [] ->
        {:error, "token_not_found"}
    end
  end
  # VALIDATION: SMELL END

  @spec token_ttl_remaining(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def token_ttl_remaining(token_string) when is_binary(token_string) do
    now = System.system_time(:second)

    case :ets.lookup(@token_store, token_string) do
      [{^token_string, %{expires_at: exp, revoked: false}}] when exp > now ->
        {:ok, exp - now}

      [{^token_string, %{revoked: true}}] ->
        {:error, "token_revoked"}

      [{^token_string, _}] ->
        {:error, "token_expired"}

      [] ->
        {:error, "token_not_found"}
    end
  end

  @spec list_active_tokens(String.t()) :: list(map())
  def list_active_tokens(subject) when is_binary(subject) do
    now = System.system_time(:second)

    :ets.tab2list(@token_store)
    |> Enum.filter(fn {_k, record} ->
      record.subject == subject and not record.revoked and record.expires_at > now
    end)
    |> Enum.map(fn {_, record} -> record end)
  end

  defp validate_scope(scope) when scope in @valid_scopes, do: :ok
  defp validate_scope(_), do: {:error, "invalid_scope"}

  defp validate_ttl(ttl) when ttl > 0 and ttl <= @max_ttl_seconds, do: :ok
  defp validate_ttl(_), do: {:error, "ttl_out_of_range"}

  defp generate_token_string do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
```
