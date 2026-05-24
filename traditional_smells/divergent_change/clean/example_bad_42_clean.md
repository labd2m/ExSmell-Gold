```elixir
defmodule MyApp.CampaignManager do
  @moduledoc """
  Manages marketing campaign lifecycle, email dispatching, engagement
  event tracking, and campaign performance analytics.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Campaign, CampaignRecipient, EngagementEvent}
  alias MyApp.Integrations.SendGrid
  import Ecto.Query



  @doc """
  Creates a new marketing campaign in draft status.
  """
  def create_campaign(attrs) do
    %Campaign{}
    |> Campaign.changeset(Map.put(attrs, :status, :draft))
    |> Repo.insert()
  end

  @doc """
  Transitions a campaign from draft to live, triggering email dispatch.
  """
  def launch_campaign(%Campaign{status: :draft} = campaign) do
    campaign
    |> Campaign.changeset(%{status: :live, launched_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, launched} = result ->
        send_to_all_recipients(launched)
        result

      error ->
        error
    end
  end

  def launch_campaign(%Campaign{}), do: {:error, :only_draft_can_be_launched}

  @doc """
  Pauses a live campaign, halting further sends.
  """
  def pause_campaign(%Campaign{status: :live} = campaign) do
    campaign
    |> Campaign.changeset(%{status: :paused, paused_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def pause_campaign(%Campaign{}), do: {:error, :only_live_can_be_paused}

  defp send_to_all_recipients(campaign) do
    Repo.all(from r in CampaignRecipient, where: r.campaign_id == ^campaign.id and r.status == :pending)
    |> Enum.each(&send_campaign_email(campaign, &1))
  end


  @doc """
  Sends the campaign email to a single recipient and updates their status.
  """
  def send_campaign_email(%Campaign{} = campaign, %CampaignRecipient{} = recipient) do
    tracking_token = encode_tracking_token(campaign.id, recipient.id)

    payload = %{
      to: [%{email: recipient.email}],
      template_id: campaign.email_template_id,
      dynamic_template_data: Map.merge(campaign.template_vars || %{}, %{
        "tracking_open_url" => "https://app.example.com/t/o/#{tracking_token}",
        "tracking_link_url" => "https://app.example.com/t/c/#{tracking_token}"
      })
    }

    case SendGrid.send_mail(payload) do
      {:ok, _} ->
        recipient
        |> CampaignRecipient.changeset(%{status: :sent, sent_at: DateTime.utc_now()})
        |> Repo.update()

      {:error, _} = err ->
        recipient
        |> CampaignRecipient.changeset(%{status: :failed})
        |> Repo.update()
        err
    end
  end

  defp encode_tracking_token(campaign_id, recipient_id) do
    "#{campaign_id}:#{recipient_id}" |> Base.url_encode64(padding: false)
  end


  @doc """
  Records that a recipient opened the campaign email.
  """
  def record_open(campaign_id, recipient_id) do
    %EngagementEvent{}
    |> EngagementEvent.changeset(%{
      campaign_id: campaign_id,
      recipient_id: recipient_id,
      event_type: :open,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Records that a recipient clicked a link in the campaign email.
  """
  def record_click(campaign_id, recipient_id, link_url) do
    %EngagementEvent{}
    |> EngagementEvent.changeset(%{
      campaign_id: campaign_id,
      recipient_id: recipient_id,
      event_type: :click,
      link_url: link_url,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end


  @doc """
  Returns an aggregated performance summary for a campaign.
  """
  def campaign_analytics(campaign_id) do
    total_sent =
      Repo.one(from r in CampaignRecipient, where: r.campaign_id == ^campaign_id and r.status == :sent, select: count(r.id))

    opens =
      Repo.one(from e in EngagementEvent, where: e.campaign_id == ^campaign_id and e.event_type == :open, select: count(e.id))

    clicks =
      Repo.one(from e in EngagementEvent, where: e.campaign_id == ^campaign_id and e.event_type == :click, select: count(e.id))

    open_rate = if total_sent > 0, do: Float.round(opens / total_sent * 100, 2), else: 0.0
    click_rate = if total_sent > 0, do: Float.round(clicks / total_sent * 100, 2), else: 0.0

    %{
      campaign_id: campaign_id,
      total_sent: total_sent,
      opens: opens,
      clicks: clicks,
      open_rate_pct: open_rate,
      click_rate_pct: click_rate
    }
  end

end
```
