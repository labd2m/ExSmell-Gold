# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Auth.SessionManager` module, `expires_at/1` macro |
| **Affected function(s)** | `expires_at/1` |
| **Short explanation** | `expires_at/1` adds a compile-time constant to a runtime `DateTime`. Although the TTL constant is known at compile time, `DateTime.add/3` is a runtime call, and a regular function with the module attribute directly referenced would be equally efficient and far simpler. |

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Creates, validates, and invalidates user sessions. Supports both
  short-lived browser sessions and long-lived API tokens with
  configurable TTLs per authentication tier.
  """

  @session_ttl_seconds 86_400
  @api_token_ttl_seconds 2_592_000
  @refresh_window_seconds 3_600

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `expires_at/1` merely calls
  # `DateTime.add/3` on a runtime `DateTime` value. Even though `@session_ttl_seconds`
  # is a compile-time constant, `DateTime.add` is evaluated at runtime.
  # A `def` function referencing the module attribute directly would be
  # completely identical in behaviour and far more readable, without
  # forcing callers to `require` this module.
  defmacro expires_at(issued_at) do
    quote do
      DateTime.add(unquote(issued_at), unquote(@session_ttl_seconds), :second)
    end
  end
  # VALIDATION: SMELL END

  def create_session(user_id, metadata \\ %{}) do
    require Auth.SessionManager

    now = DateTime.utc_now()
    token = generate_token()

    %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      token: token,
      issued_at: now,
      expires_at: Auth.SessionManager.expires_at(now),
      metadata: metadata,
      revoked: false
    }
  end

  def create_api_token(user_id, scopes) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      token: generate_token(),
      scopes: scopes,
      issued_at: now,
      expires_at: DateTime.add(now, @api_token_ttl_seconds, :second),
      revoked: false
    }
  end

  def valid?(session) do
    not session.revoked and
      DateTime.compare(DateTime.utc_now(), session.expires_at) == :lt
  end

  def expiring_soon?(session) do
    now = DateTime.utc_now()
    window_start = DateTime.add(session.expires_at, -@refresh_window_seconds, :second)
    DateTime.compare(now, window_start) != :lt and valid?(session)
  end

  def refresh(session) do
    require Auth.SessionManager

    if expiring_soon?(session) do
      now = DateTime.utc_now()
      {:ok, %{session | issued_at: now, expires_at: Auth.SessionManager.expires_at(now)}}
    else
      {:error, :not_eligible_for_refresh}
    end
  end

  def revoke(session) do
    {:ok, %{session | revoked: true}}
  end

  def revoke_all_for_user(sessions, user_id) do
    Enum.map(sessions, fn s ->
      if s.user_id == user_id, do: %{s | revoked: true}, else: s
    end)
  end

  def remaining_seconds(session) do
    diff = DateTime.diff(session.expires_at, DateTime.utc_now(), :second)
    max(diff, 0)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
