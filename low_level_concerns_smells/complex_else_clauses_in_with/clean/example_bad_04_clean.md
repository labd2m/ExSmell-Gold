```elixir
defmodule Notifications.CampaignSender do
  alias Notifications.{Repo, Campaign, Recipient, TemplateEngine, DeliveryProvider}
  alias Notifications.Subscriptions

  require Logger

  @max_batch_size 500

  def send_campaign_message(campaign_id, recipient_id, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, campaign} <- load_active_campaign(campaign_id),
         {:ok, recipient} <- load_subscribed_recipient(recipient_id, campaign),
         {:ok, rendered} <- TemplateEngine.render(campaign.template, recipient.merge_vars),
         {:ok, provider} <- resolve_delivery_provider(campaign.channel),
         {:ok, message_id} <- maybe_dispatch(provider, recipient, rendered, dry_run?) do
      log_delivery(campaign, recipient, message_id, dry_run?)
      {:ok, %{message_id: message_id, recipient_id: recipient_id}}
    else
      {:error, :not_found} ->
        Logger.warning("Campaign #{campaign_id} not found")
        {:error, :campaign_not_found}

      {:error, :inactive} ->
        Logger.warning("Campaign #{campaign_id} is not active")
        {:error, :campaign_inactive}

      {:error, :unsubscribed} ->
        Logger.info("Recipient #{recipient_id} is unsubscribed from campaign #{campaign_id}")
        {:error, :recipient_unsubscribed}

      {:error, :recipient_not_found} ->
        Logger.warning("Recipient #{recipient_id} not found")
        {:error, :recipient_not_found}

      {:error, {:render_error, reason}} ->
        Logger.error("Template render failed for campaign #{campaign_id}: #{inspect(reason)}")
        {:error, :template_error}

      {:error, :unknown_channel} ->
        Logger.error("Unknown channel for campaign #{campaign_id}: #{campaign_id}")
        {:error, :configuration_error}

      {:error, :rate_limited} ->
        Logger.warning("Provider rate-limited for campaign #{campaign_id}")
        schedule_retry(campaign_id, recipient_id)
        {:error, :rate_limited}

      {:error, :provider_error} ->
        Logger.error("Provider delivery error for campaign #{campaign_id}")
        {:error, :delivery_failed}
    end
  end

  defp load_active_campaign(campaign_id) do
    case Repo.get(Campaign, campaign_id) do
      nil -> {:error, :not_found}
      %Campaign{status: status} when status != :active -> {:error, :inactive}
      campaign -> {:ok, campaign}
    end
  end

  defp load_subscribed_recipient(recipient_id, campaign) do
    case Repo.get(Recipient, recipient_id) do
      nil ->
        {:error, :recipient_not_found}

      recipient ->
        if Subscriptions.subscribed?(recipient, campaign.list_id) do
          {:ok, recipient}
        else
          {:error, :unsubscribed}
        end
    end
  end

  defp resolve_delivery_provider(:email), do: {:ok, DeliveryProvider.Email}
  defp resolve_delivery_provider(:sms), do: {:ok, DeliveryProvider.SMS}
  defp resolve_delivery_provider(:push), do: {:ok, DeliveryProvider.Push}
  defp resolve_delivery_provider(_), do: {:error, :unknown_channel}

  defp maybe_dispatch(_provider, _recipient, rendered, true = _dry_run) do
    {:ok, "dry-run-#{System.unique_integer([:positive])}"}
  end

  defp maybe_dispatch(provider, recipient, rendered, false) do
    provider.send(recipient.contact, rendered)
  end

  defp log_delivery(campaign, recipient, message_id, dry_run?) do
    Logger.info(
      "Campaign #{campaign.id} → #{recipient.id}: #{message_id} (dry_run=#{dry_run?})"
    )
  end

  defp schedule_retry(campaign_id, recipient_id) do
    %{campaign_id: campaign_id, recipient_id: recipient_id}
    |> Notifications.RetryWorker.new(schedule_in: 600)
    |> Oban.insert()
  end
end
```
