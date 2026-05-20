# Annotated Bad Example 15

**Smell name:** Complex extractions in clauses
**Expected smell location:** `Auth.TokenValidator.validate_token/1`
**Affected functions:** `validate_token/1`
**Explanation:** Each of the three clauses in `validate_token/1` destructures six fields from the `Token` struct — `user_id`, `token_value`, `scope`, `expires_at`, `issued_at`, and `device_id` — directly in the function head. Only `scope` and `expires_at` appear in the guard expressions. The other four fields (`user_id`, `token_value`, `issued_at`, `device_id`) are extracted in the clause head purely so they can be referenced inside the function body. This conflation of guard-driving extractions with body-convenience bindings across every clause head obscures which variables are responsible for clause selection.

```elixir
defmodule Auth.TokenValidator do
  @moduledoc """
  Validates access tokens and produces authenticated session contexts.
  Handles write-scoped, read-scoped, and expired token cases.
  """

  require Logger

  alias Auth.{AuditLog, Session, TokenStore, User}

  @read_scopes ~w(read:profile read:data read:reports)
  @write_scopes ~w(write:data write:settings admin:all)
  @session_extension_hours 2

  def validate_and_refresh(raw_token) when is_binary(raw_token) do
    case TokenStore.lookup(raw_token) do
      {:ok, token} -> validate_token(token)
      {:error, :not_found} -> {:error, :invalid_token}
    end
  end

  def validate_all(raw_tokens) when is_list(raw_tokens) do
    Enum.reduce_while(raw_tokens, {:ok, []}, fn raw, {:ok, acc} ->
      case validate_and_refresh(raw) do
        {:ok, context} -> {:cont, {:ok, [context | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because all three clauses extract `user_id`,
  # `token_value`, `scope`, `expires_at`, `issued_at`, and `device_id` from the
  # Token struct in the function head. Only `scope` and `expires_at` appear in
  # the guard expressions that determine which clause fires. The remaining four
  # fields are extracted purely for use inside the function body, making it
  # non-obvious which bindings govern clause dispatch and which are convenience
  # bindings for the implementation.
  def validate_token(%Token{
        user_id: user_id,
        token_value: token_value,
        scope: scope,
        expires_at: expires_at,
        issued_at: issued_at,
        device_id: device_id
      })
      when scope in @write_scopes and expires_at > :os.system_time(:second) do
    token_age = :os.system_time(:second) - issued_at
    Logger.info("[TokenValidator] Write-scope token valid user=#{user_id} device=#{device_id}")

    with {:ok, user} <- User.fetch(user_id),
         :ok <- assert_write_enabled(user),
         {:ok, session} <- Session.extend(user_id, device_id, @session_extension_hours) do
      AuditLog.record(:token_accepted, user_id, %{
        token_hint: obfuscate(token_value),
        scope: scope,
        age_seconds: token_age,
        session_id: session.id
      })

      {:ok, %{user: user, session: session, scope: scope}}
    end
  end

  def validate_token(%Token{
        user_id: user_id,
        token_value: token_value,
        scope: scope,
        expires_at: expires_at,
        issued_at: issued_at,
        device_id: device_id
      })
      when scope in @read_scopes and expires_at > :os.system_time(:second) do
    token_age = :os.system_time(:second) - issued_at
    Logger.info("[TokenValidator] Read-scope token valid user=#{user_id} device=#{device_id}")

    with {:ok, user} <- User.fetch(user_id),
         {:ok, session} <- Session.find_or_create(user_id, device_id) do
      AuditLog.record(:token_accepted, user_id, %{
        token_hint: obfuscate(token_value),
        scope: scope,
        age_seconds: token_age,
        session_id: session.id
      })

      {:ok, %{user: user, session: session, scope: scope}}
    end
  end

  def validate_token(%Token{
        user_id: user_id,
        token_value: token_value,
        scope: scope,
        expires_at: expires_at,
        issued_at: _issued_at,
        device_id: device_id
      })
      when expires_at <= :os.system_time(:second) do
    Logger.info("[TokenValidator] Expired token user=#{user_id} scope=#{scope} device=#{device_id}")

    AuditLog.record(:token_expired, user_id, %{
      token_hint: obfuscate(token_value),
      scope: scope,
      expired_at: expires_at
    })

    {:error, :token_expired}
  end
  # VALIDATION: SMELL END

  defp assert_write_enabled(user) do
    if user.write_enabled do
      :ok
    else
      {:error, :write_permission_denied}
    end
  end

  defp obfuscate(token_value) when is_binary(token_value) do
    prefix = String.slice(token_value, 0, 8)
    "#{prefix}…[redacted]"
  end
end
```
