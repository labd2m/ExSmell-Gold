## Metadata

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `validate_claims/2` (all three primary clauses)
- **Affected function(s):** `validate_claims/2`
- **Short explanation:** Every clause of `validate_claims/2` extracts eight fields from `%TokenClaims{}` in the function head. Only `role` and `expires_at` are referenced in the guard expressions; the remaining six fields (`token_id`, `user_id`, `username`, `email`, `scope`, `issued_at`) are used exclusively inside the function body. Repeating this mixture across three clauses makes it very hard to identify what is driving clause dispatch versus what is needed only for computation.

---

```elixir
defmodule Auth.TokenValidator do
  require Logger

  alias Auth.{ClaimsStore, SessionRegistry, AuditLog, RateLimiter}
  alias Auth.Schema.TokenClaims

  @write_roles [:admin, :superadmin]
  @read_roles [:admin, :superadmin, :moderator, :analyst]
  @clock_skew_seconds 30
  @session_extension_seconds 900

  def decode_and_validate(raw_token, context) do
    with {:ok, claims} <- ClaimsStore.decode(raw_token),
         {:ok, _} <- validate_claims(claims, context) do
      {:ok, claims}
    end
  end

  def revoke(token_id) do
    ClaimsStore.revoke(token_id)
    SessionRegistry.terminate(token_id)
    :ok
  end

  def list_active_sessions(user_id) do
    SessionRegistry.list_for_user(user_id)
  end

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `token_id`, `user_id`, `username`, `email`, `scope`,
  # VALIDATION: and `issued_at` are all extracted in every clause head but are only used inside
  # VALIDATION: the function body. Only `role` and `expires_at` participate in guard expressions.
  # VALIDATION: Repeating these six body-only bindings alongside the guard-relevant fields in
  # VALIDATION: every clause makes it nearly impossible to tell what controls clause selection.
  def validate_claims(
        %TokenClaims{
          token_id: token_id,
          user_id: user_id,
          username: username,
          email: email,
          role: role,
          scope: scope,
          expires_at: expires_at,
          issued_at: issued_at
        },
        :write
      )
      when role in @write_roles and not is_nil(expires_at) do
    now = DateTime.utc_now()
    expiry_buffered = DateTime.add(expires_at, @clock_skew_seconds, :second)

    with true <- DateTime.compare(now, expiry_buffered) == :lt,
         false <- RateLimiter.throttled?(user_id, :write),
         :ok <-
           AuditLog.record(:token_validated, user_id, %{
             email: email,
             action: :write,
             token_id: token_id
           }) do
      Logger.info(
        "[TokenValidator] Write access granted user=#{username} role=#{role} scope=#{scope}"
      )

      SessionRegistry.extend(token_id, @session_extension_seconds)
      {:ok, :authorized}
    else
      false ->
        Logger.warn("[TokenValidator] Token expired for user=#{username} email=#{email}")
        {:error, :token_expired}

      true ->
        Logger.warn(
          "[TokenValidator] Write rate-limit exceeded user=#{username} issued_at=#{issued_at}"
        )

        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_claims(
        %TokenClaims{
          token_id: token_id,
          user_id: user_id,
          username: username,
          email: email,
          role: role,
          scope: scope,
          expires_at: expires_at,
          issued_at: issued_at
        },
        :read
      )
      when role in @read_roles and not is_nil(expires_at) do
    now = DateTime.utc_now()
    expiry_buffered = DateTime.add(expires_at, @clock_skew_seconds, :second)

    if DateTime.compare(now, expiry_buffered) == :lt do
      Logger.info(
        "[TokenValidator] Read access granted user=#{username} role=#{role} scope=#{scope}"
      )

      SessionRegistry.touch(token_id, user_id, issued_at)

      AuditLog.record(:token_validated, user_id, %{
        email: email,
        action: :read,
        token_id: token_id
      })

      {:ok, :authorized}
    else
      Logger.warn("[TokenValidator] Expired token for user=#{username} email=#{email}")
      {:error, :token_expired}
    end
  end

  def validate_claims(
        %TokenClaims{
          token_id: _token_id,
          user_id: user_id,
          username: username,
          email: email,
          role: role,
          scope: _scope,
          expires_at: expires_at,
          issued_at: _issued_at
        },
        _action
      )
      when role == :guest do
    if is_nil(expires_at) or DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      Logger.warn(
        "[TokenValidator] Guest token expired or missing expiry user=#{username} email=#{email}"
      )

      {:error, :token_expired}
    else
      Logger.info("[TokenValidator] Guest read-only access granted user=#{username} id=#{user_id}")
      {:ok, :authorized}
    end
  end

  # VALIDATION: SMELL END

  def validate_claims(%TokenClaims{role: role, username: username}, _action) do
    Logger.error("[TokenValidator] Unsupported role=#{role} for user=#{username}")
    {:error, :invalid_role}
  end

  defp token_age_seconds(issued_at) do
    DateTime.diff(DateTime.utc_now(), issued_at, :second)
  end
end
```
