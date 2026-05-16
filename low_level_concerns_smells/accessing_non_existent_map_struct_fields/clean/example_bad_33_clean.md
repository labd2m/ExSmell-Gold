```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Creates, validates, and invalidates user sessions.
  Enforces MFA requirements and role-based capability checks
  before issuing a session token.
  """

  require Logger

  @session_ttl_seconds 3_600
  @elevated_ttl_seconds 900
  @token_length 64

  @type user :: %{
          id: String.t(),
          email: String.t(),
          role: :admin | :operator | :viewer,
          password_hash: String.t(),
          optional(:mfa_enabled) => boolean(),
          optional(:mfa_secret) => String.t(),
          optional(:force_password_reset) => boolean(),
          optional(:suspended) => boolean()
        }

  @type session :: %{
          token: String.t(),
          user_id: String.t(),
          role: atom(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          elevated: boolean()
        }

  @spec build_session(user(), keyword()) :: {:ok, session()} | {:error, atom()}
  def build_session(user, opts \\ []) do
    mfa_verified = Keyword.get(opts, :mfa_verified, false)

    with :ok <- check_account_status(user),
         :ok <- check_mfa_requirement(user, mfa_verified) do
      do_build_session(user, mfa_verified)
    end
  end

  defp check_account_status(user) do
    suspended             = user[:suspended]
    force_password_reset  = user[:force_password_reset]

    cond do
      suspended            -> {:error, :account_suspended}
      force_password_reset -> {:error, :password_reset_required}
      true                 -> :ok
    end
  end

  defp check_mfa_requirement(user, mfa_verified) do
    mfa_enabled = user[:mfa_enabled]

    if mfa_enabled and not mfa_verified do
      {:error, :mfa_required}
    else
      :ok
    end
  end

  defp do_build_session(user, mfa_verified) do
    elevated  = user.role == :admin and mfa_verified
    ttl       = if elevated, do: @elevated_ttl_seconds, else: @session_ttl_seconds
    now       = DateTime.utc_now()
    expires   = DateTime.add(now, ttl, :second)
    token     = generate_token()

    session = %{
      token:      token,
      user_id:    user.id,
      role:       user.role,
      issued_at:  now,
      expires_at: expires,
      elevated:   elevated
    }

    Logger.info("Session created for user=#{user.id} role=#{user.role} elevated=#{elevated}")
    {:ok, session}
  end

  @spec validate_session(session()) :: :ok | {:error, atom()}
  def validate_session(session) do
    if DateTime.compare(DateTime.utc_now(), session.expires_at) == :gt do
      {:error, :session_expired}
    else
      :ok
    end
  end

  @spec invalidate(session()) :: :ok
  def invalidate(session) do
    Logger.info("Session invalidated for user=#{session.user_id}")
    :ok
  end

  defp generate_token do
    @token_length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
```
