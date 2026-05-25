# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `CampaignManager` module
- **Affected functions:** `create_campaign/1`, `activate_campaign/1`, `pause_campaign/1`, `add_audience_segment/2`, `remove_audience_segment/2`, `schedule_send/2`, `execute_send/1`, `track_open/2`, `track_click/2`, `generate_performance_report/1`
- **Short explanation:** `CampaignManager` combines campaign lifecycle (CRUD, activate, pause), audience segmentation, send scheduling, actual email dispatching, engagement event tracking (opens, clicks), and performance reporting. These are distinct concerns — campaign administration, audience management, delivery engine, event ingestion, and analytics — that should live in separate modules.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because CampaignManager manages campaign
# state transitions, audience segment assignment, message scheduling and
# delivery, engagement event ingestion (opens/clicks), and performance
# analytics reporting — five separate marketing platform subdomain concerns
# packed into one oversized, incoherent module.
defmodule CampaignManager do
  @moduledoc """
  Full-cycle campaign management: creation, activation, audience segmentation,
  scheduled and immediate delivery, engagement tracking (opens/clicks), and
  performance reporting.
  """

  require Logger
  import Ecto.Query
  alias Marketing.Repo
  alias Marketing.Campaign
  alias Marketing.CampaignSegment
  alias Marketing.CampaignSend
  alias Marketing.EngagementEvent
  alias Marketing.Contact

  @batch_size 200

  # --- Campaign creation ---

  def create_campaign(attrs) do
    changeset =
      Campaign.changeset(%Campaign{}, %{
        name: attrs[:name],
        subject: attrs[:subject],
        html_body: attrs[:html_body],
        text_body: attrs[:text_body],
        from_name: attrs[:from_name] || "Marketing Team",
        from_email: attrs[:from_email] || "marketing@example.com",
        status: :draft,
        created_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, campaign} ->
        Logger.info("Campaign #{campaign.id} '#{campaign.name}' created as draft")
        {:ok, campaign}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Lifecycle management ---

  def activate_campaign(%Campaign{status: :draft} = campaign) do
    campaign
    |> Campaign.changeset(%{status: :active, activated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def activate_campaign(%Campaign{status: status}), do: {:error, {:cannot_activate, status}}

  def pause_campaign(%Campaign{status: :active} = campaign) do
    campaign
    |> Campaign.changeset(%{status: :paused, paused_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def pause_campaign(%Campaign{status: status}), do: {:error, {:cannot_pause, status}}

  # --- Audience segmentation ---

  def add_audience_segment(%Campaign{} = campaign, segment_id) do
    attrs = %{campaign_id: campaign.id, segment_id: segment_id}

    case Repo.insert(CampaignSegment.changeset(%CampaignSegment{}, attrs)) do
      {:ok, cs} ->
        Logger.info("Segment #{segment_id} added to campaign #{campaign.id}")
        {:ok, cs}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def remove_audience_segment(%Campaign{} = campaign, segment_id) do
    case Repo.get_by(CampaignSegment, campaign_id: campaign.id, segment_id: segment_id) do
      nil -> {:error, :not_found}
      cs  -> Repo.delete(cs)
    end
  end

  # --- Scheduling ---

  def schedule_send(%Campaign{} = campaign, scheduled_at) do
    if DateTime.compare(scheduled_at, DateTime.utc_now()) == :lt do
      {:error, :scheduled_at_must_be_future}
    else
      campaign
      |> Campaign.changeset(%{scheduled_at: scheduled_at})
      |> Repo.update()
    end
  end

  # --- Delivery engine ---

  def execute_send(%Campaign{status: status}) when status not in [:active] do
    {:error, :campaign_not_active}
  end

  def execute_send(%Campaign{} = campaign) do
    contacts = resolve_contacts(campaign)

    Logger.info("Executing send for campaign #{campaign.id} to #{length(contacts)} contacts")

    contacts
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn contact ->
        personalised_body = personalise(campaign.html_body, contact)

        result =
          Mailer.deliver(%{
            to: contact.email,
            from: {campaign.from_name, campaign.from_email},
            subject: campaign.subject,
            html_body: personalised_body
          })

        status = if match?({:ok, _}, result), do: :delivered, else: :failed

        Repo.insert!(
          CampaignSend.changeset(%CampaignSend{}, %{
            campaign_id: campaign.id,
            contact_id: contact.id,
            status: status,
            sent_at: DateTime.utc_now()
          })
        )
      end)
    end)

    campaign
    |> Campaign.changeset(%{status: :sent, sent_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp resolve_contacts(%Campaign{} = campaign) do
    segment_ids =
      from(cs in CampaignSegment, where: cs.campaign_id == ^campaign.id, select: cs.segment_id)
      |> Repo.all()

    from(c in Contact,
      join: sc in "segment_contacts", on: sc.contact_id == c.id,
      where: sc.segment_id in ^segment_ids and c.unsubscribed == false,
      distinct: true
    )
    |> Repo.all()
  end

  defp personalise(template, contact) do
    template
    |> String.replace("{{first_name}}", contact.first_name || "there")
    |> String.replace("{{email}}", contact.email)
  end

  # --- Engagement tracking ---

  def track_open(send_id, metadata \\ %{}) do
    case Repo.get(CampaignSend, send_id) do
      nil ->
        {:error, :not_found}

      send ->
        Repo.insert!(
          EngagementEvent.changeset(%EngagementEvent{}, %{
            campaign_send_id: send.id,
            campaign_id: send.campaign_id,
            contact_id: send.contact_id,
            type: :open,
            metadata: metadata,
            occurred_at: DateTime.utc_now()
          })
        )

        :ok
    end
  end

  def track_click(send_id, url) do
    case Repo.get(CampaignSend, send_id) do
      nil ->
        {:error, :not_found}

      send ->
        Repo.insert!(
          EngagementEvent.changeset(%EngagementEvent{}, %{
            campaign_send_id: send.id,
            campaign_id: send.campaign_id,
            contact_id: send.contact_id,
            type: :click,
            metadata: %{url: url},
            occurred_at: DateTime.utc_now()
          })
        )

        :ok
    end
  end

  # --- Performance reporting ---

  def generate_performance_report(%Campaign{} = campaign) do
    sends = from(s in CampaignSend, where: s.campaign_id == ^campaign.id) |> Repo.all()

    total     = length(sends)
    delivered = Enum.count(sends, &(&1.status == :delivered))

    opens  = from(e in EngagementEvent, where: e.campaign_id == ^campaign.id and e.type == :open) |> Repo.aggregate(:count, :id)
    clicks = from(e in EngagementEvent, where: e.campaign_id == ^campaign.id and e.type == :click) |> Repo.aggregate(:count, :id)

    %{
      campaign_id: campaign.id,
      name: campaign.name,
      total_recipients: total,
      delivered: delivered,
      opens: opens,
      clicks: clicks,
      open_rate: if(delivered > 0, do: Float.round(opens / delivered * 100, 1), else: 0.0),
      click_rate: if(delivered > 0, do: Float.round(clicks / delivered * 100, 1), else: 0.0)
    }
  end
end
# VALIDATION: SMELL END
```
