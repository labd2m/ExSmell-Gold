```elixir
defmodule AssetManagement.AssetTransferService do
  alias AssetManagement.{Repo, Asset, Account, TransferRecord, ComplianceGate, AuditLog}

  require Logger

  @transfer_cooldown_days 7

  def transfer_asset(asset_id, from_account_id, to_account_id) do
    with {:ok, asset} <- fetch_transferable_asset(asset_id),
         :ok <- verify_ownership(asset, from_account_id),
         {:ok, recipient} <- fetch_eligible_recipient(to_account_id),
         :ok <- ComplianceGate.check_transfer(asset, from_account_id, to_account_id),
         {:ok, record} <- record_transfer(asset, from_account_id, to_account_id) do
      asset
      |> Asset.changeset(%{
        owner_account_id: to_account_id,
        last_transferred_at: DateTime.utc_now()
      })
      |> Repo.update()

      AuditLog.append(:asset_transferred, %{
        asset_id: asset_id,
        from: from_account_id,
        to: to_account_id,
        record_id: record.id
      })

      Logger.info(
        "Asset #{asset_id} transferred from account #{from_account_id} " <>
          "to #{to_account_id} (record=#{record.id})"
      )

      {:ok, record}
    else
      {:error, :asset_not_found} ->
        Logger.warning("Asset #{asset_id} not found during transfer")
        {:error, :asset_not_found}

      {:error, :asset_not_transferable} ->
        Logger.warning("Asset #{asset_id} is locked and cannot be transferred")
        {:error, :asset_locked}

      {:error, :not_the_owner} ->
        Logger.warning(
          "Account #{from_account_id} does not own asset #{asset_id}"
        )
        {:error, :unauthorized_transfer}

      {:error, :recipient_not_found} ->
        Logger.warning("Recipient account #{to_account_id} not found")
        {:error, :recipient_not_found}

      {:error, :recipient_suspended} ->
        Logger.warning("Recipient account #{to_account_id} is suspended")
        {:error, :recipient_ineligible}

      {:error, :compliance_hold} ->
        Logger.warning("Compliance hold on asset #{asset_id} — transfer blocked")
        {:error, :compliance_blocked}

      {:error, :cross_border_restricted} ->
        Logger.warning("Cross-border restriction applies to asset #{asset_id} transfer")
        {:error, :compliance_blocked}

      {:error, :cooldown_active} ->
        Logger.info("Asset #{asset_id} is within the #{@transfer_cooldown_days}-day transfer cooldown")
        {:error, :transfer_cooldown}

      {:error, :record_failed} ->
        Logger.error("Transfer record persistence failed for asset #{asset_id}")
        {:error, :persistence_error}
    end
  end

  defp fetch_transferable_asset(asset_id) do
    case Repo.get(Asset, asset_id) do
      nil -> {:error, :asset_not_found}
      %Asset{transferable: false} -> {:error, :asset_not_transferable}
      asset -> {:ok, asset}
    end
  end

  defp verify_ownership(%Asset{owner_account_id: owner_id}, from_account_id) do
    if owner_id == from_account_id, do: :ok, else: {:error, :not_the_owner}
  end

  defp fetch_eligible_recipient(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :recipient_not_found}
      %Account{status: :suspended} -> {:error, :recipient_suspended}
      account -> {:ok, account}
    end
  end

  defp record_transfer(asset, from_account_id, to_account_id) do
    %TransferRecord{}
    |> TransferRecord.changeset(%{
      asset_id: asset.id,
      from_account_id: from_account_id,
      to_account_id: to_account_id,
      transferred_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, rec} -> {:ok, rec}
      {:error, _} -> {:error, :record_failed}
    end
  end
end
```
