```elixir
defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Dispatches transactional and notification emails via the configured
  SMTP adapter. Each dispatch is logged for deliverability tracking
  and retry management.
  """

  require Logger

  alias Notifications.{EmailTemplate, DeliveryLog, RetryQueue, DigestStore}
  alias Notifications.Adapters.SMTPAdapter

  @max_retries 3
  @retry_backoff_base_seconds 60

  @spec dispatch(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def dispatch(template_id, context) do
    with {:ok, template} <- EmailTemplate.fetch(template_id),
         {:ok, rendered} <- EmailTemplate.render(template, context),
         {:ok, log_id} <- DeliveryLog.create(template_id, context[:recipient_email]) do
      case SMTPAdapter.send(rendered) do
        {:ok, message_id} ->
          DeliveryLog.mark_sent(log_id, message_id)
          Logger.info("Email dispatched template=#{template_id} log=#{log_id} msg=#{message_id}")
          {:ok, log_id}

        {:error, :temporary_failure} ->
          enqueue_retry(log_id, template_id, context)
          Logger.warning("Email dispatch failed, retrying log=#{log_id}")
          {:error, :temporary_failure}

        {:error, reason} ->
          DeliveryLog.mark_failed(log_id, reason)
          Logger.error("Email dispatch failed permanently log=#{log_id}: #{inspect(reason)}")
          {:error, :dispatch_failed}
      end
    end
  end

  @spec flush_retries() :: {:ok, non_neg_integer()}
  def flush_retries do
    eligible = RetryQueue.pop_due()

    results =
      Enum.map(eligible, fn %{log_id: log_id, template_id: tid, context: ctx, attempts: n} ->
        if n >= @max_retries do
          DeliveryLog.mark_exhausted(log_id)
          :exhausted
        else
          dispatch(tid, ctx)
        end
      end)

    sent = Enum.count(results, &match?({:ok, _}, &1))
    Logger.info("Retry flush completed sent=#{sent} total=#{length(results)}")
    {:ok, sent}
  end

  
  
  
  
  
  
  
  def schedule_digest(recipient_email, template_id, cadence \\ :daily) do
    interval_hours =
      case cadence do
        :daily -> 24
        :weekly -> 168
      end

    send_at = DateTime.add(DateTime.utc_now(), interval_hours * 3_600, :second)

    case DigestStore.upsert(recipient_email, template_id, send_at) do
      {:ok, digest_entry} ->
        Logger.info(
          "Digest scheduled recipient=#{recipient_email} " <>
            "template=#{template_id} cadence=#{cadence} send_at=#{send_at}"
        )

        {:ok, digest_entry}

      {:error, reason} ->
        Logger.error("Digest schedule failed recipient=#{recipient_email}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  

  defp enqueue_retry(log_id, template_id, context) do
    attempts = DeliveryLog.attempt_count(log_id)
    backoff = @retry_backoff_base_seconds * :math.pow(2, attempts) |> round()
    retry_at = DateTime.add(DateTime.utc_now(), backoff, :second)
    RetryQueue.push(%{log_id: log_id, template_id: template_id, context: context, retry_at: retry_at, attempts: attempts + 1})
  end
end

defmodule Notifications.NotificationWorker do
  alias Notifications.{EmailDispatcher, PendingNotification}

  require Logger

  def process_pending do
    PendingNotification.list_due()
    |> Enum.each(fn notif ->
      case EmailDispatcher.dispatch(notif.template_id, notif.context) do
        {:ok, log_id} ->
          PendingNotification.mark_dispatched(notif.id, log_id)

        {:error, reason} ->
          Logger.warning("Notification dispatch failed id=#{notif.id}: #{inspect(reason)}")
      end
    end)
  end
end
```
