```elixir
defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Dispatches transactional emails to recipients using rendered templates.
  Manages delivery queuing, preference enforcement, and retry tracking.
  """

  alias Notifications.{DeliveryLog, EmailQueue}
  alias Recipients.Recipient
  alias Templates.Template

  require Logger

  @max_retry_attempts 3
  @default_sender_address "noreply@platform.example.com"
  @default_sender_name "Platform Notifications"

  @spec dispatch(String.t(), String.t(), map()) ::
          {:ok, :delivered | :skipped} | {:error, atom()}
  def dispatch(recipient_id, template_name, variables \\ %{}) do
    with {:ok, recipient} <- Recipient.fetch(recipient_id),
         :ok             <- ensure_email_verified(recipient) do

      prefs    = Recipient.load_contact_preferences(recipient)
      template = Template.compile(template_name, prefs.preferred_language)

      if template_name in prefs.unsubscribed_topics do
        Logger.info("[EmailDispatcher] Suppressed #{template_name} for recipient=#{recipient_id}")
        {:ok, :skipped}
      else
        message = %{
          to:        prefs.email_address,
          from:      "#{@default_sender_name} <#{@default_sender_address}>",
          subject:   template.subject,
          html_body: interpolate(template.html_body, variables),
          text_body: interpolate(template.text_body, variables)
        }

        delivery_id = enqueue_message(message, recipient_id, template_name)

        Logger.debug("[EmailDispatcher] Queued delivery=#{delivery_id} template=#{template_name}")
        {:ok, :delivered}
      end
    end
  end

  @spec retry_failed(String.t()) :: :ok | {:error, atom()}
  def retry_failed(delivery_id) do
    with {:ok, log} <- DeliveryLog.find(delivery_id),
         :ok        <- ensure_in_failed_state(log) do
      if log.attempt_count < @max_retry_attempts do
        :ok = EmailQueue.requeue(delivery_id)
        :ok = DeliveryLog.increment_attempts(delivery_id)
        :ok
      else
        {:error, :max_retries_exceeded}
      end
    end
  end

  @spec mark_delivered(String.t()) :: :ok
  def mark_delivered(delivery_id) do
    :ok = DeliveryLog.mark_delivered(delivery_id, DateTime.utc_now())
    Logger.debug("[EmailDispatcher] Confirmed delivery=#{delivery_id}")
    :ok
  end

  @spec mark_bounced(String.t(), String.t()) :: :ok
  def mark_bounced(delivery_id, bounce_reason) when is_binary(bounce_reason) do
    :ok = DeliveryLog.mark_bounced(delivery_id, bounce_reason, DateTime.utc_now())
    Logger.warning("[EmailDispatcher] Bounce on delivery=#{delivery_id}: #{bounce_reason}")
    :ok
  end

  @spec list_failed(non_neg_integer()) :: [DeliveryLog.t()]
  def list_failed(limit \\ 100) when limit > 0 do
    DeliveryLog.list_by_status(:failed, limit: limit)
  end


  defp ensure_email_verified(%{email_verified: true}), do: :ok
  defp ensure_email_verified(%{email_verified: false}), do: {:error, :email_not_verified}
  defp ensure_email_verified(_), do: {:error, :verification_status_unknown}

  defp interpolate(template_body, variables) do
    Enum.reduce(variables, template_body, fn {key, value}, body ->
      String.replace(body, "{{#{key}}}", to_string(value))
    end)
  end

  defp enqueue_message(message, recipient_id, template_name) do
    delivery_id = generate_delivery_id()

    EmailQueue.enqueue(%{
      id:            delivery_id,
      message:       message,
      recipient_id:  recipient_id,
      template_name: template_name,
      attempt_count: 0,
      queued_at:     DateTime.utc_now()
    })

    delivery_id
  end

  defp ensure_in_failed_state(%{status: :failed}), do: :ok
  defp ensure_in_failed_state(_), do: {:error, :delivery_not_in_failed_state}

  defp generate_delivery_id do
    "DLV-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
```
