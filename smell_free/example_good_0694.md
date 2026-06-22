```elixir
defmodule Accounts.DeviceContext do
  @moduledoc """
  Tracks trusted devices for user accounts. A device is enrolled
  by verifying a one-time code sent to the user's email. Enrolled devices
  skip MFA prompts for a configurable period. The context enforces a
  maximum number of enrolled devices per user to limit exposure.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.{TrustedDevice, User}

  @type user_id :: String.t()
  @type device_id :: Ecto.UUID.t()
  @type fingerprint :: String.t()

  @max_devices_per_user 5
  @trust_duration_days 90

  @doc """
  Enrolls a device for `user_id` identified by `fingerprint`. Evicts
  the oldest device when the per-user limit is reached.
  """
  @spec enroll(user_id(), fingerprint(), String.t()) ::
          {:ok, TrustedDevice.t()} | {:error, Ecto.Changeset.t()}
  def enroll(user_id, fingerprint, user_agent)
      when is_binary(user_id) and is_binary(fingerprint) do
    Repo.transaction(fn ->
      evict_if_at_capacity(user_id)
      expires_at = DateTime.add(DateTime.utc_now(), @trust_duration_days * 86_400, :second)

      attrs = %{
        user_id: user_id,
        fingerprint_hash: hash(fingerprint),
        user_agent: user_agent,
        expires_at: expires_at
      }

      case %TrustedDevice{} |> TrustedDevice.changeset(attrs) |> Repo.insert() do
        {:ok, device} -> device
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Returns true when the device identified by `fingerprint` is currently
  trusted for `user_id` and has not expired.
  """
  @spec trusted?(user_id(), fingerprint()) :: boolean()
  def trusted?(user_id, fingerprint) when is_binary(user_id) and is_binary(fingerprint) do
    now = DateTime.utc_now()
    hash = hash(fingerprint)

    Repo.exists?(
      from(d in TrustedDevice,
        where: d.user_id == ^user_id and d.fingerprint_hash == ^hash
               and d.expires_at > ^now
      )
    )
  end

  @doc "Removes a specific trusted device."
  @spec revoke(device_id(), user_id()) :: :ok | {:error, :not_found}
  def revoke(device_id, user_id) when is_binary(device_id) do
    case Repo.get_by(TrustedDevice, id: device_id, user_id: user_id) do
      nil -> {:error, :not_found}
      device ->
        Repo.delete!(device)
        :ok
    end
  end

  @doc "Removes all trusted devices for `user_id`."
  @spec revoke_all(user_id()) :: {:ok, non_neg_integer()}
  def revoke_all(user_id) when is_binary(user_id) do
    {count, _} = Repo.delete_all(from(d in TrustedDevice, where: d.user_id == ^user_id))
    {:ok, count}
  end

  @doc "Returns all active trusted devices for `user_id`."
  @spec list(user_id()) :: [TrustedDevice.t()]
  def list(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    from(d in TrustedDevice,
      where: d.user_id == ^user_id and d.expires_at > ^now,
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
  end

  defp evict_if_at_capacity(user_id) do
    devices = list(user_id)

    if length(devices) >= @max_devices_per_user do
      oldest = List.last(devices)
      Repo.delete!(oldest)
    end
  end

  defp hash(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
```
