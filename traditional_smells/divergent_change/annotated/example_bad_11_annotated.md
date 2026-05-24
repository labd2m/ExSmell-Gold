# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `CampaignManager` module |
| **Affected functions** | `create_campaign/1`, `launch_campaign/1`, `pause_campaign/1`, `archive_campaign/1` (campaign lifecycle reason) and `send_campaign_emails/1`, `track_open/2`, `track_click/2` (email sending/tracking reason) and `get_campaign_stats/1`, `calculate_conversion_rate/1`, `export_performance_report/1` (analytics reason) |
| **Explanation** | The module mixes campaign state management, email delivery and tracking, and campaign analytics — three independent marketing automation concerns. Changes to the email delivery provider, to the tracking pixel implementation, or to the reporting metrics would each independently require changes to this module. |

```elixir
defmodule Marketing.CampaignManager do
  @moduledoc """
  Manages marketing campaign lifecycle, email delivery, and performance analytics.
  """

  alias Marketing.Repo
  alias Marketing.Campaigns.Campaign
  alias Marketing.Campaigns.EmailDelivery
  alias Marketing.Campaigns.TrackingEvent
  alias Marketing.Mailer

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three unrelated reasons
  # to change: (1) campaign lifecycle state transitions, (2) email delivery
  # mechanics and engagement tracking, and (3) analytics and reporting on
  # campaign performance. Each concern belongs in its own module.

  ## ── Campaign Lifecycle ───────────────────────────────────────────────────────

  @doc "Creates a new email campaign in draft state."
  @spec create_campaign(map()) :: {:ok, Campaign.t()} | {:error, Ecto.Changeset.t()}
  def create_campaign(attrs) do
    %Campaign{}
    |> Campaign.changeset(Map.merge(attrs, %{status: :draft, created_at: DateTime.utc_now()}))
    |> Repo.insert()
  end

  @doc "Launches a draft campaign, making it eligible for immediate or scheduled sending."
  @spec launch_campaign(Campaign.t()) :: {:ok, Campaign.t()} | {:error, atom()}
  def launch_campaign(%Campaign{status: :draft} = campaign) do
    if campaign_valid?(campaign) do
      campaign
      |> Campaign.changeset(%{status: :active, launched_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :campaign_incomplete}
    end
  end

  def launch_campaign(%Campaign{}), do: {:error, :invalid_status}

  @doc "Pauses an active campaign to temporarily halt new email sends."
  @spec pause_campaign(Campaign.t()) :: {:ok, Campaign.t()} | {:error, atom()}
  def pause_campaign(%Campaign{status: :active} = campaign) do
    campaign
    |> Campaign.changeset(%{status: :paused, paused_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def pause_campaign(%Campaign{}), do: {:error, :not_active}

  @doc "Archives a completed or cancelled campaign."
  @spec archive_campaign(Campaign.t()) :: {:ok, Campaign.t()} | {:error, atom()}
  def archive_campaign(%Campaign{status: status} = campaign)
      when status in [:paused, :completed, :draft] do
    campaign
    |> Campaign.changeset(%{status: :archived, archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def archive_campaign(%Campaign{}), do: {:error, :cannot_archive}

  ## ── Email Sending & Tracking ─────────────────────────────────────────────────

  @doc "Dispatches campaign emails to all eligible subscribers in the target segment."
  @spec send_campaign_emails(Campaign.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def send_campaign_emails(%Campaign{id: campaign_id, segment_id: seg_id} = campaign) do
    subscribers = Marketing.Segments.list_active_subscribers(seg_id)
    Logger.info("Sending campaign #{campaign_id} to #{length(subscribers)} subscribers")

    results =
      Enum.map(subscribers, fn subscriber ->
        delivery_attrs = %{
          campaign_id: campaign_id,
          subscriber_id: subscriber.id,
          status: :pending,
          sent_at: nil
        }

        {:ok, delivery} =
          %EmailDelivery{} |> EmailDelivery.changeset(delivery_attrs) |> Repo.insert()

        case Mailer.deliver_campaign_email(subscriber, campaign) do
          {:ok, _} ->
            delivery |> EmailDelivery.changeset(%{status: :sent, sent_at: DateTime.utc_now()}) |> Repo.update!()
            :ok

          {:error, reason} ->
            Logger.error("Failed to deliver to #{subscriber.id}: #{inspect(reason)}")
            delivery |> EmailDelivery.changeset(%{status: :failed}) |> Repo.update!()
            {:error, subscriber.id}
        end
      end)

    sent_count = Enum.count(results, &(&1 == :ok))
    {:ok, sent_count}
  end

  @doc "Records that a subscriber opened the campaign email."
  @spec track_open(String.t(), String.t()) :: :ok
  def track_open(campaign_id, subscriber_id) do
    attrs = %{
      campaign_id: campaign_id,
      subscriber_id: subscriber_id,
      event_type: :open,
      occurred_at: DateTime.utc_now()
    }

    %TrackingEvent{} |> TrackingEvent.changeset(attrs) |> Repo.insert(on_conflict: :nothing)
    :ok
  end

  @doc "Records that a subscriber clicked a link in the campaign email."
  @spec track_click(String.t(), map()) :: :ok
  def track_click(campaign_id, %{subscriber_id: sub_id, url: url}) do
    attrs = %{
      campaign_id: campaign_id,
      subscriber_id: sub_id,
      event_type: :click,
      metadata: %{url: url},
      occurred_at: DateTime.utc_now()
    }

    %TrackingEvent{} |> TrackingEvent.changeset(attrs) |> Repo.insert()
    :ok
  end

  ## ── Analytics & Reporting ────────────────────────────────────────────────────

  @doc "Returns delivery, open, and click statistics for a campaign."
  @spec get_campaign_stats(Campaign.t()) :: map()
  def get_campaign_stats(%Campaign{id: campaign_id}) do
    deliveries =
      EmailDelivery |> where([d], d.campaign_id == ^campaign_id) |> Repo.aggregate(:count, :id)

    sent = EmailDelivery |> where([d], d.campaign_id == ^campaign_id and d.status == :sent) |> Repo.aggregate(:count, :id)

    opens =
      TrackingEvent
      |> where([e], e.campaign_id == ^campaign_id and e.event_type == :open)
      |> select([e], count(e.subscriber_id, :distinct))
      |> Repo.one()

    clicks =
      TrackingEvent
      |> where([e], e.campaign_id == ^campaign_id and e.event_type == :click)
      |> select([e], count(e.subscriber_id, :distinct))
      |> Repo.one()

    %{total_recipients: deliveries, sent: sent, opens: opens || 0, clicks: clicks || 0}
  end

  @doc "Calculates the conversion rate (clicks / sent) for a campaign."
  @spec calculate_conversion_rate(Campaign.t()) :: float()
  def calculate_conversion_rate(%Campaign{} = campaign) do
    %{sent: sent, clicks: clicks} = get_campaign_stats(campaign)
    if sent > 0, do: Float.round(clicks / sent * 100, 2), else: 0.0
  end

  @doc "Exports a full performance summary for stakeholder reporting."
  @spec export_performance_report(Campaign.t()) :: map()
  def export_performance_report(%Campaign{id: cid, name: name} = campaign) do
    stats = get_campaign_stats(campaign)
    conversion = calculate_conversion_rate(campaign)
    open_rate = if stats.sent > 0, do: Float.round(stats.opens / stats.sent * 100, 2), else: 0.0

    %{
      campaign_id: cid,
      campaign_name: name,
      stats: stats,
      open_rate_pct: open_rate,
      conversion_rate_pct: conversion,
      exported_at: DateTime.utc_now()
    }
  end

  ## ── Private Helpers ──────────────────────────────────────────────────────────

  defp campaign_valid?(%Campaign{subject: s, body_html: b, segment_id: seg})
       when is_binary(s) and is_binary(b) and not is_nil(seg),
       do: true

  defp campaign_valid?(_), do: false

  # VALIDATION: SMELL END
end
```
