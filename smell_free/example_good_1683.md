```elixir
defmodule Auth.TwoFactorContext do
  @moduledoc """
  Manages TOTP-based two-factor authentication enrollment, verification,
  and recovery code generation. Secrets are stored encrypted; plaintext
  is never persisted and is only returned during initial enrollment.
  """

  alias Auth.{Repo, TwoFactorCredential, UserContext}

  @totp_digits 6
  @totp_period 30
  @recovery_code_count 8
  @recovery_code_length 10

  @type user_id :: String.t()

  @type enroll_result :: %{
          secret: String.t(),
          uri: String.t(),
          recovery_codes: [String.t()]
        }

  @spec enroll(user_id(), String.t()) ::
          {:ok, enroll_result()} | {:error, :already_enrolled | Ecto.Changeset.t()}
  def enroll(user_id, issuer) when is_binary(user_id) and is_binary(issuer) do
    if enrolled?(user_id) do
      {:error, :already_enrolled}
    else
      secret = NimbleTOTP.secret()
      recovery_codes = generate_recovery_codes()
      hashed_codes = Enum.map(recovery_codes, &hash_recovery_code/1)

      with {:ok, _} <- persist_enrollment(user_id, secret, hashed_codes) do
        uri = totp_uri(user_id, secret, issuer)
        plaintext_secret = Base.encode32(secret, padding: false)
        {:ok, %{secret: plaintext_secret, uri: uri, recovery_codes: recovery_codes}}
      end
    end
  end

  @spec verify_totp(user_id(), String.t()) :: :ok | {:error, :not_enrolled | :invalid_code}
  def verify_totp(user_id, code) when is_binary(user_id) and is_binary(code) do
    case Repo.get_by(TwoFactorCredential, user_id: user_id, active: true) do
      nil ->
        {:error, :not_enrolled}

      credential ->
        if NimbleTOTP.valid?(credential.encrypted_secret, code, digits: @totp_digits, period: @totp_period) do
          :ok
        else
          {:error, :invalid_code}
        end
    end
  end

  @spec use_recovery_code(user_id(), String.t()) :: :ok | {:error, :not_enrolled | :invalid_code}
  def use_recovery_code(user_id, code) when is_binary(user_id) and is_binary(code) do
    case Repo.get_by(TwoFactorCredential, user_id: user_id, active: true) do
      nil ->
        {:error, :not_enrolled}

      credential ->
        code_hash = hash_recovery_code(code)
        remaining = credential.recovery_code_hashes

        if code_hash in remaining do
          updated_codes = List.delete(remaining, code_hash)
          credential
          |> TwoFactorCredential.update_changeset(%{recovery_code_hashes: updated_codes})
          |> Repo.update()
          :ok
        else
          {:error, :invalid_code}
        end
    end
  end

  @spec revoke(user_id()) :: :ok | {:error, :not_enrolled}
  def revoke(user_id) when is_binary(user_id) do
    case Repo.get_by(TwoFactorCredential, user_id: user_id, active: true) do
      nil ->
        {:error, :not_enrolled}

      credential ->
        credential
        |> TwoFactorCredential.update_changeset(%{active: false, revoked_at: DateTime.utc_now()})
        |> Repo.update()
        :ok
    end
  end

  @spec enrolled?(user_id()) :: boolean()
  def enrolled?(user_id) when is_binary(user_id) do
    Repo.exists?(
      from c in TwoFactorCredential,
        where: c.user_id == ^user_id and c.active == true
    )
  end

  @spec persist_enrollment(user_id(), binary(), [String.t()]) ::
          {:ok, TwoFactorCredential.t()} | {:error, Ecto.Changeset.t()}
  defp persist_enrollment(user_id, secret, hashed_codes) do
    %TwoFactorCredential{}
    |> TwoFactorCredential.creation_changeset(%{
      user_id: user_id,
      encrypted_secret: secret,
      recovery_code_hashes: hashed_codes,
      active: true
    })
    |> Repo.insert()
  end

  @spec generate_recovery_codes() :: [String.t()]
  defp generate_recovery_codes do
    Enum.map(1..@recovery_code_count, fn _ ->
      :crypto.strong_rand_bytes(@recovery_code_length)
      |> Base.encode32(padding: false)
      |> String.slice(0, @recovery_code_length)
      |> String.upcase()
    end)
  end

  @spec hash_recovery_code(String.t()) :: String.t()
  defp hash_recovery_code(code) do
    :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
  end

  @spec totp_uri(user_id(), binary(), String.t()) :: String.t()
  defp totp_uri(user_id, secret, issuer) do
    NimbleTOTP.otpauth_uri("#{issuer}:#{user_id}", secret, issuer: issuer)
  end
end
```
