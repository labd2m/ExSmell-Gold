# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `VerificationService.token_ttl_seconds/1` and `VerificationService.user_instructions/1`
- **Affected functions:** `token_ttl_seconds/1`, `user_instructions/1`
- **Short explanation:** The same `case` branching over verification method (`:email_link`, `:sms_otp`, `:totp`, `:backup_code`) is duplicated in `token_ttl_seconds/1` and `user_instructions/1`. Introducing a new verification method requires edits in both functions.

---

```elixir
defmodule VerificationService do
  @moduledoc """
  Issues and validates identity verification tokens across multiple
  methods (email magic link, SMS OTP, TOTP authenticator, backup codes)
  for a multi-factor authentication system.
  """

  alias VerificationService.{
    VerificationToken,
    User,
    TokenStore,
    SmsGateway,
    EmailMailer,
    AuditLog
  }

  @type verification_method :: :email_link | :sms_otp | :totp | :backup_code

  @spec issue(User.t(), verification_method()) ::
          {:ok, VerificationToken.t()} | {:error, String.t()}
  def issue(%User{} = user, method) do
    with :ok <- method_available?(user, method) do
      ttl = token_ttl_seconds(method)
      token = generate_token(method)
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      vt = %VerificationToken{
        user_id: user.id,
        method: method,
        token: token,
        expires_at: expires_at
      }

      TokenStore.persist(vt, ttl: ttl)
      dispatch_token(user, method, token)
      AuditLog.record(:verification_issued, user.id, %{method: method})
      {:ok, vt}
    end
  end

  @spec verify(String.t(), verification_method(), String.t()) ::
          :ok | {:error, :invalid_token} | {:error, :expired}
  def verify(user_id, method, submitted_token) do
    case TokenStore.fetch(user_id, method) do
      {:ok, %VerificationToken{token: stored, expires_at: exp}} ->
        cond do
          DateTime.compare(exp, DateTime.utc_now()) == :lt ->
            {:error, :expired}

          not Plug.Crypto.secure_compare(stored, submitted_token) ->
            {:error, :invalid_token}

          true ->
            TokenStore.invalidate(user_id, method)
            AuditLog.record(:verification_success, user_id, %{method: method})
            :ok
        end

      {:error, :not_found} ->
        {:error, :invalid_token}
    end
  end

  @spec challenge_screen_data(User.t(), verification_method()) :: map()
  def challenge_screen_data(%User{} = user, method) do
    %{
      method: method,
      instructions: user_instructions(method),
      ttl_seconds: token_ttl_seconds(method),
      masked_destination: masked_destination(user, method)
    }
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `method`
  # also appears in `user_instructions/1` below. Both enumerate :email_link,
  # :sms_otp, :totp, :backup_code — adding a new method requires touching both.
  @spec token_ttl_seconds(verification_method()) :: integer()
  def token_ttl_seconds(method) do
    case method do
      :email_link  -> 900
      :sms_otp     -> 300
      :totp        -> 30
      :backup_code -> 120
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `method`
  # already appeared in `token_ttl_seconds/1` above. All four verification method
  # atoms are repeated, requiring parallel maintenance on any method change.
  @spec user_instructions(verification_method()) :: String.t()
  def user_instructions(method) do
    case method do
      :email_link ->
        "Click the secure link we sent to your email address."

      :sms_otp ->
        "Enter the 6-digit code sent to your phone via SMS."

      :totp ->
        "Enter the 6-digit code from your authenticator app."

      :backup_code ->
        "Enter one of your unused backup recovery codes."
    end
  end
  # VALIDATION: SMELL END

  @spec method_available?(User.t(), verification_method()) :: :ok | {:error, String.t()}
  defp method_available?(%User{mfa_methods: methods}, method) do
    if method in methods do
      :ok
    else
      {:error, "verification method #{method} is not enabled for this user"}
    end
  end

  @spec dispatch_token(User.t(), verification_method(), String.t()) :: :ok
  defp dispatch_token(%User{email: email}, :email_link, token) do
    EmailMailer.send_magic_link(email, token)
  end

  defp dispatch_token(%User{phone: phone}, :sms_otp, token) do
    SmsGateway.send_otp(phone, token)
  end

  defp dispatch_token(_user, _method, _token), do: :ok

  @spec generate_token(verification_method()) :: String.t()
  defp generate_token(:totp), do: :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  defp generate_token(:backup_code), do: :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false)
  defp generate_token(_), do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @spec masked_destination(User.t(), verification_method()) :: String.t()
  defp masked_destination(%User{email: email}, :email_link) do
    [local, domain] = String.split(email, "@")
    "#{String.slice(local, 0, 2)}***@#{domain}"
  end

  defp masked_destination(%User{phone: phone}, :sms_otp) do
    "***#{String.slice(phone, -4, 4)}"
  end

  defp masked_destination(_user, _method), do: ""
end
```
