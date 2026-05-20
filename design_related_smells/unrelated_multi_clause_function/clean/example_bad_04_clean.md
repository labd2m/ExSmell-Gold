```elixir
defmodule SchedulerWorker do
  @moduledoc """
  Handles execution of periodic background jobs triggered by the scheduler.
  """

  alias SchedulerWorker.{
    SessionCleanupJob,
    OverduePaymentReminderJob,
    CatalogSyncJob,
    Repo,
    Mailer,
    CatalogAPI,
    Logger
  }

  @doc """
  Executes a scheduled background job.

  ## Examples

      iex> SchedulerWorker.execute(%SessionCleanupJob{older_than_hours: 24})
      {:ok, %{deleted: 42}}

  """


  def execute(%SessionCleanupJob{older_than_hours: hours}) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    {count, _} = Repo.delete_expired_sessions(cutoff)

    Logger.info("SessionCleanupJob: removed #{count} sessions older than #{hours}h")

    {:ok, %{deleted: count, cutoff: cutoff}}
  end

  # sends email reminders for invoices past their due date
  def execute(%OverduePaymentReminderJob{grace_period_days: grace, max_reminders: max}) do
    overdue_invoices =
      Repo.fetch_overdue_invoices(grace_period_days: grace, max_prior_reminders: max)

    results =
      Enum.map(overdue_invoices, fn invoice ->
        case Mailer.send_overdue_reminder(invoice) do
          {:ok, _} ->
            Repo.record_reminder_sent(invoice.id)
            {:ok, invoice.id}

          {:error, reason} ->
            Logger.warning("Failed to send reminder for invoice #{invoice.id}: #{inspect(reason)}")
            {:error, invoice.id}
        end
      end)

    sent = Enum.count(results, &match?({:ok, _}, &1))
    failed = length(results) - sent

    {:ok, %{sent: sent, failed: failed, total: length(overdue_invoices)}}
  end

  # syncs the product catalog from the external supplier API
  def execute(%CatalogSyncJob{supplier_id: supplier_id, full_sync: full_sync}) do
    Logger.info("CatalogSyncJob: starting sync for supplier #{supplier_id}")

    fetch_opts = if full_sync, do: [since: nil], else: [since: last_sync_timestamp(supplier_id)]

    with {:ok, products} <- CatalogAPI.fetch_products(supplier_id, fetch_opts),
         {:ok, upserted} <- Repo.upsert_products(products),
         {:ok, _} <- Repo.update_sync_timestamp(supplier_id, DateTime.utc_now()) do
      Logger.info("CatalogSyncJob: upserted #{upserted} products for supplier #{supplier_id}")
      {:ok, %{upserted: upserted, supplier_id: supplier_id}}
    else
      {:error, :api_unavailable} ->
        Logger.error("CatalogSyncJob: supplier API unavailable for #{supplier_id}")
        {:error, :api_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end


  defp last_sync_timestamp(supplier_id) do
    case Repo.get_last_sync(supplier_id) do
      nil -> DateTime.add(DateTime.utc_now(), -86_400, :second)
      ts -> ts
    end
  end
end
```
