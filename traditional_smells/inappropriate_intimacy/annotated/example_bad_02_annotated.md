# Code Smell: Inappropriate Intimacy — Example 02

| Field                    | Value |
|--------------------------|-------|
| **Smell Name**           | Inappropriate Intimacy |
| **Expected Smell Location** | `Auth.TokenIssuer.issue/2` |
| **Affected Function(s)** | `issue/2` |
| **Explanation**          | `issue/2` calls `User.load_security_profile/1` and `Device.fetch_fingerprint/1` from foreign modules, then reads their internal struct fields directly (`profile.mfa_enabled`, `profile.allowed_scopes`, `profile.session_timeout_seconds`, `fingerprint.trust_level`, `fingerprint.last_verified_at`). `TokenIssuer` accumulates knowledge of `SecurityProfile` and `DeviceFingerprint` internals that belong exclusively to the `User` and `Device` modules. |

```elixir
defmodule Auth.TokenIssuer do
  @moduledoc """
  Issues JWT access and refresh tokens for authenticated users.
  Handles the token lifecycle: issuance, refresh, and revocation.
  """

  alias Auth.{Token, RefreshToken, TokenStore}
  alias Accounts.User
  alias Devices.Device

  require Logger

  @access_token_ttl_seconds 900
  @refresh_token_ttl_seconds 2_592_000
  @issuer "myapp.internal"
  @default_scopes ~w(read)

  @spec issue(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def issue(user_id, device_id) do
    with {:ok, user}   <- User.fetch(user_id),
         :ok           <- ensure_account_active(user),
         {:ok, device} <- Device.fetch(device_id),
         :ok           <- ensure_device_registered(device) do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because issue/2 calls User.load_security_profile/1 and
      # VALIDATION: Device.fetch_fingerprint/1 from foreign modules, then reads internal struct
      # VALIDATION: fields directly: profile.mfa_enabled, profile.allowed_scopes,
      # VALIDATION: profile.session_timeout_seconds, fingerprint.trust_level, and
      # VALIDATION: fingerprint.last_verified_at. TokenIssuer is forced to understand the
      # VALIDATION: internal structure of SecurityProfile and DeviceFingerprint — coupling
      # VALIDATION: it to implementation details that should stay inside User and Device.
      profile     = User.load_security_profile(user)
      fingerprint = Device.fetch_fingerprint(device)

      effective_ttl =
        if profile.session_timeout_seconds do
          min(@access_token_ttl_seconds, profile.session_timeout_seconds)
        else
          @access_token_ttl_seconds
        end

      scopes = if profile.allowed_scopes != [], do: profile.allowed_scopes, else: @default_scopes

      claims = %{
        sub:                user_id,
        iss:                @issuer,
        iat:                System.system_time(:second),
        exp:                System.system_time(:second) + effective_ttl,
        scopes:             scopes,
        mfa_verified:       profile.mfa_enabled,
        device_trust_level: fingerprint.trust_level,
        device_checked_at:  DateTime.to_unix(fingerprint.last_verified_at)
      }
      # VALIDATION: SMELL END

      access_token  = Token.sign(claims)
      refresh_token = generate_refresh_token(user_id, device_id)

      :ok = TokenStore.register(access_token, claims)
      Logger.info("Token issued for user=#{user_id} device=#{device_id}")

      {:ok, %{
        access_token:  access_token,
        refresh_token: refresh_token,
        expires_in:    effective_ttl,
        token_type:    "Bearer"
      }}
    end
  end

  @spec revoke(String.t()) :: :ok | {:error, atom()}
  def revoke(access_token) do
    case TokenStore.find(access_token) do
      {:ok, claims} ->
        :ok = TokenStore.invalidate(access_token)
        Logger.info("Token revoked for user=#{claims.sub}")
        :ok

      {:error, :not_found} ->
        {:error, :token_not_found}
    end
  end

  @spec refresh(String.t()) :: {:ok, map()} | {:error, atom()}
  def refresh(refresh_token_value) do
    with {:ok, rt} <- RefreshToken.find(refresh_token_value),
         :ok       <- ensure_refresh_token_valid(rt) do
      :ok = RefreshToken.consume(rt)
      issue(rt.user_id, rt.device_id)
    end
  end

  @spec revoke_all_for_user(String.t()) :: {:ok, non_neg_integer()}
  def revoke_all_for_user(user_id) do
    tokens = TokenStore.list_for_user(user_id)
    Enum.each(tokens, &TokenStore.invalidate/1)
    Logger.info("Revoked #{length(tokens)} token(s) for user=#{user_id}")
    {:ok, length(tokens)}
  end

  ## Private helpers

  defp generate_refresh_token(user_id, device_id) do
    raw        = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @refresh_token_ttl_seconds, :second)

    {:ok, rt} =
      %RefreshToken{
        token:      raw,
        user_id:    user_id,
        device_id:  device_id,
        expires_at: expires_at
      }
      |> RefreshToken.insert()

    rt.token
  end

  defp ensure_account_active(%{status: :active}), do: :ok
  defp ensure_account_active(%{status: :suspended}), do: {:error, :account_suspended}
  defp ensure_account_active(_), do: {:error, :account_inactive}

  defp ensure_device_registered(%{registered: true}), do: :ok
  defp ensure_device_registered(_), do: {:error, :device_not_registered}

  defp ensure_refresh_token_valid(%{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :refresh_token_expired}
  end
end
```
