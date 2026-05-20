```elixir
defmodule DataSyncWorker do
  @moduledoc """
  Background worker for syncing data between the platform and
  third-party integrations including CRM, ERP, and payment systems.
  """

  alias DataSyncWorker.{
    CrmSyncJob,
    ErpInventorySyncJob,
    PaymentReconciliationJob,
    CrmClient,
    ErpClient,
    PaymentGatewayClient,
    ContactStore,
    InventoryStore,
    TransactionStore,
    SyncLog,
    AlertManager
  }

  require Logger

  @doc """
  Execute a data synchronization job.

  Accepts a `%CrmSyncJob{}`, `%ErpInventorySyncJob{}`, or
  `%PaymentReconciliationJob{}` and performs the corresponding sync.

  ## Examples

      iex> DataSyncWorker.sync(%CrmSyncJob{tenant_id: "t1", since: ~U[2024-05-01 00:00:00Z]})
      {:ok, %{upserted: 142, errors: 0}}

  """
  def sync(%CrmSyncJob{
        tenant_id: tenant_id,
        crm_integration_id: integration_id,
        since: since,
        direction: direction
      })
      when direction in [:pull, :push, :bidirectional] do
    with {:ok, creds} <- CrmClient.get_credentials(integration_id),
         {:ok, remote_contacts} <- CrmClient.fetch_contacts_since(creds, since),
         {:ok, local_contacts} <- ContactStore.list_modified_since(tenant_id, since),
         {:ok, changeset} <- resolve_crm_conflicts(remote_contacts, local_contacts, direction),
         {:ok, result} <- apply_crm_changeset(tenant_id, creds, changeset),
         :ok <-
           SyncLog.record(%{
             type: :crm,
             tenant_id: tenant_id,
             integration_id: integration_id,
             upserted: result.upserted,
             deleted: result.deleted,
             errors: result.errors,
             synced_at: DateTime.utc_now()
           }) do
      Logger.info("CRM sync for tenant #{tenant_id}: #{result.upserted} upserted, #{result.errors} errors")
      {:ok, result}
    end
  end

  # sync inventory levels from ERP to local warehouse store
  def sync(%ErpInventorySyncJob{
        warehouse_ids: warehouse_ids,
        erp_connection_id: erp_id,
        full_refresh: full_refresh
      }) do
    fetch_opts = if full_refresh, do: [mode: :full], else: [mode: :delta]

    with {:ok, conn} <- ErpClient.connect(erp_id),
         {:ok, erp_items} <- ErpClient.fetch_inventory(conn, warehouse_ids, fetch_opts),
         batch_results =
           Enum.map(erp_items, fn item ->
             InventoryStore.upsert(%{
               sku: item.sku,
               warehouse_id: item.warehouse_id,
               qty_on_hand: item.qty,
               qty_reserved: item.reserved,
               unit_cost: item.cost,
               last_erp_sync: DateTime.utc_now()
             })
           end),
         errors = Enum.filter(batch_results, &match?({:error, _}, &1)),
         :ok <- maybe_alert_sync_errors(:erp, errors),
         :ok <-
           SyncLog.record(%{
             type: :erp_inventory,
             erp_id: erp_id,
             total: length(erp_items),
             errors: length(errors),
             full_refresh: full_refresh,
             synced_at: DateTime.utc_now()
           }) do
      Logger.info("ERP inventory sync: #{length(erp_items)} items, #{length(errors)} errors")
      {:ok, %{total: length(erp_items), errors: length(errors)}}
    end
  end

  # sync payment reconciliation between gateway and transaction ledger
  def sync(%PaymentReconciliationJob{
        gateway: gateway,
        date: recon_date,
        account_id: account_id
      }) do
    with {:ok, gateway_txns} <- PaymentGatewayClient.list_settlements(gateway, account_id, recon_date),
         {:ok, local_txns} <- TransactionStore.list_by_date(recon_date, account_id),
         {matched, unmatched_gateway, unmatched_local} =
           reconcile_transactions(gateway_txns, local_txns),
         :ok <- mark_reconciled(matched),
         :ok <- flag_discrepancies(unmatched_gateway, unmatched_local),
         :ok <-
           SyncLog.record(%{
             type: :payment_reconciliation,
             gateway: gateway,
             date: recon_date,
             matched: length(matched),
             unmatched_gateway: length(unmatched_gateway),
             unmatched_local: length(unmatched_local),
             synced_at: DateTime.utc_now()
           }),
         :ok <- maybe_alert_sync_errors(:reconciliation, unmatched_gateway ++ unmatched_local) do
      Logger.info(
        "Reconciliation for #{recon_date} on #{gateway}: #{length(matched)} matched, #{length(unmatched_gateway)} gateway-only, #{length(unmatched_local)} local-only"
      )

      {:ok, %{matched: length(matched), discrepancies: length(unmatched_gateway) + length(unmatched_local)}}
    end
  end

  defp resolve_crm_conflicts(remote, local, :pull), do: {:ok, %{to_upsert_local: remote, to_push_remote: []}}
  defp resolve_crm_conflicts(remote, local, :push), do: {:ok, %{to_upsert_local: [], to_push_remote: local}}

  defp resolve_crm_conflicts(remote, local, :bidirectional) do
    {:ok, %{to_upsert_local: remote, to_push_remote: local}}
  end

  defp apply_crm_changeset(tenant_id, creds, changeset) do
    upserted =
      Enum.count(changeset.to_upsert_local, fn c ->
        match?({:ok, _}, ContactStore.upsert(tenant_id, c))
      end)

    pushed =
      Enum.count(changeset.to_push_remote, fn c ->
        match?({:ok, _}, CrmClient.push_contact(creds, c))
      end)

    {:ok, %{upserted: upserted, deleted: 0, errors: 0, pushed: pushed}}
  end

  defp reconcile_transactions(gateway_txns, local_txns) do
    gateway_map = Map.new(gateway_txns, &{&1.reference_id, &1})
    local_map = Map.new(local_txns, &{&1.gateway_reference, &1})

    matched = Enum.filter(gateway_txns, fn g -> Map.has_key?(local_map, g.reference_id) end)
    unmatched_gateway = Enum.filter(gateway_txns, fn g -> not Map.has_key?(local_map, g.reference_id) end)
    unmatched_local = Enum.filter(local_txns, fn l -> not Map.has_key?(gateway_map, l.gateway_reference) end)

    {matched, unmatched_gateway, unmatched_local}
  end

  defp mark_reconciled(matched) do
    Enum.each(matched, fn txn -> TransactionStore.mark_reconciled(txn.id) end)
    :ok
  end

  defp flag_discrepancies(gateway_only, local_only) do
    Enum.each(gateway_only ++ local_only, fn txn -> AlertManager.flag_reconciliation_gap(txn) end)
    :ok
  end

  defp maybe_alert_sync_errors(_type, []), do: :ok
  defp maybe_alert_sync_errors(type, errors) do
    AlertManager.notify_sync_errors(type, length(errors))
  end
end
```
