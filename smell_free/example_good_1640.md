```elixir
defmodule Platform.Identity.MfaEnrollment do
  @moduledoc """
  Manages multi-factor authentication enrollment and verification flows.

  Supports TOTP-based second factors with per-user enrollment state
  tracking and backup code issuance.
  """

  alias Platform.Identity.{User, MfaRecord, BackupCodeStore}
  alias Platform.Repo

  @totp_issuer "Platform"
  @backup_code_count 8

  @type enroll_result ::
          {:ok, %{secret: String.t(), provisioning_uri: String.t(), backup_codes: [String.t()]}}
          | {:error, :already_enrolled}
          | {:error, Ecto.Changeset.t()}

  @type verify_result :: :ok | {:error, :invalid_code} | {:error, :not_enrolled}

  @doc """
  Begins TOTP enrollment for a user, generating a new secret and backup codes.

  Returns a provisioning URI suitable for QR code generation.
  Fails if the user is already enrolled.
  """
  @spec begin_enrollment(User.t()) :: enroll_result()
  def begin_enrollment(%User{mfa_enrolled: true}), do: {:error, :already_enrolled}

  def begin_enrollment(%User{} = user) do
    secret = NimbleTOTP.secret()
    provisioning_uri = NimbleTOTP.otpauth_uri("#{@totp_issuer}:#{user.email}", secret)
    backup_codes = generate_backup_codes()

    with {:ok, _record} <- store_pending_enrollment(user.id, secret),
         :ok <- BackupCodeStore.store(user.id, backup_codes) do
      {:ok,
       %{
         secret: Base.encode32(secret, padding: false),
         provisioning_uri: provisioning_uri,
         backup_codes: backup_codes
       }}
    end
  end

  @doc """
  Confirms TOTP enrollment by verifying the user's first code submission.

  Activates MFA on success; removes pending enrollment on failure.
  """
  @spec confirm_enrollment(User.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_code}
  def confirm_enrollment(%User{} = user, submitted_code) when is_binary(submitted_code) do
    with {:ok, record} <- fetch_pending_record(user.id),
         :ok <- verify_totp(record.secret, submitted_code) do
      activate_mfa(user, record)
    end
  end

  @doc """
  Verifies a TOTP code for an already-enrolled user.
  """
  @spec verify_code(User.t(), String.t()) :: verify_result()
  def verify_code(%User{mfa_enrolled: false}, _code), do: {:error, :not_enrolled}

  def verify_code(%User{} = user, submitted_code) when is_binary(submitted_code) do
    with {:ok, record} <- fetch_active_record(user.id) do
      verify_totp(record.secret, submitted_code)
    end
  end

  @doc """
  Verifies a one-time backup code, consuming it on success.
  """
  @spec verify_backup_code(User.t(), String.t()) :: verify_result()
  def verify_backup_code(%User{mfa_enrolled: false}, _code), do: {:error, :not_enrolled}

  def verify_backup_code(%User{} = user, code) when is_binary(code) do
    BackupCodeStore.consume(user.id, code)
  end

  defp generate_backup_codes do
    for _ <- 1..@backup_code_count do
      :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false, case: :lower)
    end
  end

  defp store_pending_enrollment(user_id, secret) do
    %MfaRecord{}
    |> MfaRecord.changeset(%{user_id: user_id, secret: secret, status: :pending})
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :user_id)
  end

  defp fetch_pending_record(user_id) do
    case Repo.get_by(MfaRecord, user_id: user_id, status: :pending) do
      nil -> {:error, :invalid_code}
      record -> {:ok, record}
    end
  end

  defp fetch_active_record(user_id) do
    case Repo.get_by(MfaRecord, user_id: user_id, status: :active) do
      nil -> {:error, :not_enrolled}
      record -> {:ok, record}
    end
  end

  defp verify_totp(secret, code) do
    if NimbleTOTP.valid?(secret, code) do
      :ok
    else
      {:error, :invalid_code}
    end
  end

  defp activate_mfa(user, record) do
    Repo.transaction(fn ->
      {:ok, _} = Repo.update(MfaRecord.changeset(record, %{status: :active}))
      {:ok, updated_user} = user |> User.mfa_changeset(%{mfa_enrolled: true}) |> Repo.update()
      updated_user
    end)
  end
end
```
