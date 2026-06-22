```elixir
defmodule Auth.Totp do
  @moduledoc """
  Manages Time-based One-Time Password (TOTP) two-factor authentication.
  Secret generation, QR code URI construction, code verification, and
  backup code management are all centralised here. Verification uses a
  one-step tolerance window to accommodate slight clock skew between the
  user's device and the server without opening the window so wide that
  code replay becomes practical.
  """

  alias Auth.{BackupCode, TotpSecret, Repo}
  alias Ecto.Multi

  require Logger

  @issuer "MyApp"
  @digits 6
  @period 30
  @window 1
  @backup_code_count 10

  @type user_id :: binary()

  @doc """
  Generates a new TOTP secret for `user_id` and returns the provisioning URI
  for QR code display. The secret is stored but marked as not yet verified;
  verification must be confirmed with `confirm_enrollment/2` before 2FA
  is considered active for the user.
  """
  @spec begin_enrollment(user_id(), binary()) ::
          {:ok, %{secret: binary(), provisioning_uri: binary()}} | {:error, term()}
  def begin_enrollment(user_id, user_email)
      when is_binary(user_id) and is_binary(user_email) do
    secret = NimbleOTP.TOTP.generate_secret()
    encoded = Base.encode32(secret, padding: false)

    uri = NimbleOTP.TOTP.otpauth_uri(@issuer, user_email, secret,
      digits: @digits, period: @period)

    case upsert_secret(user_id, encoded) do
      {:ok, _} -> {:ok, %{secret: encoded, provisioning_uri: uri}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies `code` against the pending secret for `user_id` and, if valid,
  marks the enrollment as confirmed and generates backup codes.
  Returns `{:ok, backup_codes}` or `{:error, :invalid_code}`.
  """
  @spec confirm_enrollment(user_id(), binary()) ::
          {:ok, [binary()]} | {:error, :invalid_code | :no_pending_enrollment | term()}
  def confirm_enrollment(user_id, code) when is_binary(user_id) and is_binary(code) do
    with {:ok, secret_record} <- fetch_unconfirmed(user_id),
         :ok <- verify_code(secret_record.secret, code) do
      backup_codes = generate_backup_codes()

      Multi.new()
      |> Multi.update(:secret, TotpSecret.confirm_changeset(secret_record))
      |> Multi.run(:backup_codes, fn repo, _ ->
        hashed = Enum.map(backup_codes, &BackupCode.hash_code/1)

        rows = Enum.map(hashed, fn h ->
          %{user_id: user_id, code_hash: h,
            inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
        end)

        {count, _} = repo.insert_all(BackupCode, rows)
        {:ok, count}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _} -> {:ok, backup_codes}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Verifies a TOTP `code` for an already-enrolled user.
  Falls back to backup code verification when the code is longer than 6 digits.
  """
  @spec verify(user_id(), binary()) :: :ok | {:error, :invalid_code | :not_enrolled}
  def verify(user_id, code) when is_binary(user_id) and is_binary(code) do
    with {:ok, secret_record} <- fetch_confirmed(user_id) do
      if String.length(code) > @digits do
        verify_backup_code(user_id, code)
      else
        verify_code(secret_record.secret, code)
      end
    end
  end

  @doc """
  Disables TOTP for `user_id`, removing the secret and all backup codes.
  """
  @spec disable(user_id()) :: :ok | {:error, term()}
  def disable(user_id) when is_binary(user_id) do
    Multi.new()
    |> Multi.delete_all(:secret, from(s in TotpSecret, where: s.user_id == ^user_id))
    |> Multi.delete_all(:backup_codes, from(b in BackupCode, where: b.user_id == ^user_id))
    |> Repo.transaction()
    |> case do
      {:ok, _} ->
        Logger.info("TOTP disabled", user_id: user_id)
        :ok

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upsert_secret(user_id, encoded) do
    attrs = %{user_id: user_id, secret: encoded, confirmed: false}

    %TotpSecret{}
    |> TotpSecret.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:secret, :confirmed, :updated_at]},
                   conflict_target: :user_id)
  end

  defp fetch_unconfirmed(user_id) do
    case Repo.get_by(TotpSecret, user_id: user_id, confirmed: false) do
      nil -> {:error, :no_pending_enrollment}
      record -> {:ok, record}
    end
  end

  defp fetch_confirmed(user_id) do
    case Repo.get_by(TotpSecret, user_id: user_id, confirmed: true) do
      nil -> {:error, :not_enrolled}
      record -> {:ok, record}
    end
  end

  defp verify_code(encoded_secret, code) do
    secret = Base.decode32!(encoded_secret, padding: false)

    if NimbleOTP.TOTP.valid?(code, secret, period: @period, digits: @digits, window: @window) do
      :ok
    else
      {:error, :invalid_code}
    end
  end

  defp verify_backup_code(user_id, code) do
    hashed = BackupCode.hash_code(code)

    case Repo.get_by(BackupCode, user_id: user_id, code_hash: hashed, used: false) do
      nil ->
        {:error, :invalid_code}

      backup ->
        backup |> BackupCode.use_changeset() |> Repo.update()
        :ok
    end
  end

  defp generate_backup_codes do
    Enum.map(1..@backup_code_count, fn _ ->
      :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    end)
  end
end
```
