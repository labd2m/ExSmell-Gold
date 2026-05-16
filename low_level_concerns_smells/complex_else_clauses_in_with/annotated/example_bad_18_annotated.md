# Annotated Bad Example 18

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `register_device/3`, inside the `with` block's `else` clause
- **Affected function(s):** `register_device/3`
- **Short explanation:** Device registration runs five steps—account lookup, device-limit enforcement, certificate validation, device record creation, and push notification setup. All these steps fail with different error shapes that are collapsed into a single `else` block, losing the structural distinction between each failure category.

```elixir
defmodule DeviceManagement.DeviceRegistrar do
  alias DeviceManagement.{Repo, Account, Device, CertificateValidator, PushNotificationService}

  require Logger

  @max_devices_per_account 25

  def register_device(account_id, device_params, certificate_pem) do
    with {:ok, account} <- fetch_verified_account(account_id),
         :ok <- check_device_limit(account),
         {:ok, cert_info} <- CertificateValidator.validate(certificate_pem),
         {:ok, device} <- persist_device(account, device_params, cert_info),
         {:ok, push_token} <- PushNotificationService.register(device) do
      device
      |> Device.changeset(%{push_token: push_token, registered_at: DateTime.utc_now()})
      |> Repo.update()

      Logger.info(
        "Device #{device.id} registered for account #{account_id} " <>
          "(type=#{device.device_type} os=#{device.os_version})"
      )

      {:ok, %{device_id: device.id, push_token: push_token}}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because the `else` block handles errors from five
      # different pipeline steps without any structural grouping. `:not_found` and
      # `:unverified` come from account fetching; `:device_limit_reached` from the limit
      # check; `:certificate_expired`, `:certificate_invalid`, `:certificate_revoked` from
      # certificate validation; `{:db_error, _}` from device persistence; and
      # `:push_registration_failed` from push notification setup — all in one block.
      {:error, :not_found} ->
        Logger.warning("Account #{account_id} not found during device registration")
        {:error, :account_not_found}

      {:error, :unverified} ->
        Logger.warning("Device registration blocked — account #{account_id} email not verified")
        {:error, :account_not_verified}

      {:error, :device_limit_reached} ->
        Logger.warning("Account #{account_id} has reached the maximum device limit")
        {:error, :device_limit_reached}

      {:error, :certificate_expired} ->
        Logger.warning("Expired certificate presented for account #{account_id}")
        {:error, :invalid_certificate}

      {:error, :certificate_invalid} ->
        Logger.warning("Invalid certificate format for account #{account_id}")
        {:error, :invalid_certificate}

      {:error, :certificate_revoked} ->
        Logger.warning("Revoked certificate presented for account #{account_id}")
        {:error, :certificate_revoked}

      {:error, {:db_error, changeset}} ->
        Logger.error("Device persistence failed: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}

      {:error, :push_registration_failed} ->
        Logger.error("Push notification registration failed for account #{account_id}")
        {:error, :push_setup_failed}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_verified_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      %Account{email_verified: false} -> {:error, :unverified}
      account -> {:ok, account}
    end
  end

  defp check_device_limit(account) do
    count = Repo.count(from d in Device, where: d.account_id == ^account.id and d.status == :active)

    if count >= @max_devices_per_account do
      {:error, :device_limit_reached}
    else
      :ok
    end
  end

  defp persist_device(account, params, cert_info) do
    %Device{}
    |> Device.changeset(%{
      account_id: account.id,
      device_type: params.device_type,
      os_version: params.os_version,
      model: params.model,
      certificate_fingerprint: cert_info.fingerprint,
      certificate_expires_at: cert_info.expires_at,
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, device} -> {:ok, device}
      {:error, cs} -> {:error, {:db_error, cs}}
    end
  end
end
```
