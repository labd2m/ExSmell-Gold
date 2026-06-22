```elixir
defmodule MyApp.Accounts.DeviceRegistry do
  @moduledoc """
  Tracks trusted devices for multi-factor authentication bypass. When a
  user successfully completes MFA on a new device, it can be registered
  as trusted so that subsequent logins from the same device skip the
  second factor for a configurable period.

  Device fingerprints are hashed before storage so that a database
  breach does not expose raw device identifiers.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.{User, TrustedDevice}

  @trust_duration_days 90
  @fingerprint_salt Application.compile_env!(:my_app, :device_fingerprint_salt)

  @type user_id :: String.t()
  @type raw_fingerprint :: String.t()

  @doc """
  Registers `raw_fingerprint` as a trusted device for `user_id`.
  Returns `{:ok, device}` or, if already trusted, `{:ok, existing}`.
  """
  @spec register(user_id(), raw_fingerprint(), String.t()) ::
          {:ok, TrustedDevice.t()} | {:error, Ecto.Changeset.t()}
  def register(user_id, raw_fingerprint, label \\ "Unknown Device")
      when is_binary(user_id) and is_binary(raw_fingerprint) do
    hashed = hash_fingerprint(raw_fingerprint)
    expires_at = DateTime.add(DateTime.utc_now(), @trust_duration_days, :day)

    case Repo.get_by(TrustedDevice, user_id: user_id, fingerprint_hash: hashed) do
      %TrustedDevice{} = existing ->
        {:ok, existing}

      nil ->
        %TrustedDevice{}
        |> TrustedDevice.changeset(%{
          user_id: user_id,
          fingerprint_hash: hashed,
          label: label,
          expires_at: expires_at
        })
        |> Repo.insert()
    end
  end

  @doc """
  Returns `true` when `raw_fingerprint` is a currently trusted device
  for `user_id`.
  """
  @spec trusted?(user_id(), raw_fingerprint()) :: boolean()
  def trusted?(user_id, raw_fingerprint) when is_binary(user_id) and is_binary(raw_fingerprint) do
    hashed = hash_fingerprint(raw_fingerprint)
    now = DateTime.utc_now()

    TrustedDevice
    |> where([d], d.user_id == ^user_id and d.fingerprint_hash == ^hashed and d.expires_at > ^now)
    |> Repo.exists?()
  end

  @doc "Revokes the trusted device identified by `device_id` for `user_id`."
  @spec revoke(user_id(), String.t()) :: :ok | {:error, :not_found}
  def revoke(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case Repo.get_by(TrustedDevice, id: device_id, user_id: user_id) do
      nil -> {:error, :not_found}
      device -> Repo.delete(device) && :ok
    end
  end

  @doc "Revokes all trusted devices for `user_id`."
  @spec revoke_all(user_id()) :: non_neg_integer()
  def revoke_all(user_id) when is_binary(user_id) do
    {count, _} =
      TrustedDevice
      |> where([d], d.user_id == ^user_id)
      |> Repo.delete_all()

    count
  end

  @doc "Returns all active trusted devices for `user_id`."
  @spec list(user_id()) :: [TrustedDevice.t()]
  def list(user_id) when is_binary(user_id) do
    TrustedDevice
    |> where([d], d.user_id == ^user_id and d.expires_at > ^DateTime.utc_now())
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @spec hash_fingerprint(raw_fingerprint()) :: String.t()
  defp hash_fingerprint(raw) do
    :crypto.mac(:hmac, :sha256, @fingerprint_salt, raw)
    |> Base.encode16(case: :lower)
  end
end
```
