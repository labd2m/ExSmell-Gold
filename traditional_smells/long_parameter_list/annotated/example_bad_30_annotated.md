# Annotated Example 30 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Marketing.Campaigns.launch_campaign/11` |
| **Affected function(s)** | `launch_campaign/11` |
| **Explanation** | The function takes 11 individual parameters covering campaign metadata (name, description, owner_id), audience targeting (segment_id, exclude_unsubscribed), content (subject, body_template_id), scheduling (start_at, end_at), tracking (utm_source, utm_medium). These naturally belong in a `%CampaignDetails{}` and a `%AudienceConfig{}` struct rather than a flat list of eleven arguments. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `launch_campaign/11` accepts eleven
# individual positional parameters. Campaign metadata (name, description,
# owner_id), audience targeting (segment_id, exclude_unsubscribed),
# email content (subject, body_template_id), scheduling windows (start_at,
# end_at), and analytics tracking parameters (utm_source, utm_medium)
# are all jammed into one long, flat signature. The boolean and several
# string-typed arguments at the end are especially easy to mix up.
defmodule Marketing.Campaigns do
  @moduledoc """
  Manages marketing campaign creation, audience resolution,
  scheduling, and delivery via the email marketing subsystem.
  """

  require Logger

  alias Marketing.Repo
  alias Marketing.Schemas.Campaign
  alias Marketing.Schemas.CampaignDelivery
  alias Marketing.SegmentResolver
  alias Marketing.TemplateStore
  alias Marketing.Scheduler
  alias Marketing.Mailer

  @valid_utm_sources ~w(email newsletter product_update)

  def launch_campaign(
        name,
        description,
        owner_id,
        segment_id,
        exclude_unsubscribed,
        subject,
        body_template_id,
        start_at,
        end_at,
        utm_source,
        utm_medium
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_name(name),
         :ok <- validate_subject(subject),
         {:ok, template} <- TemplateStore.fetch(body_template_id),
         {:ok, segment} <- SegmentResolver.fetch(segment_id),
         :ok <- validate_schedule(start_at, end_at) do
      audience =
        if exclude_unsubscribed do
          SegmentResolver.exclude_unsubscribed(segment)
        else
          segment.members
        end

      campaign_attrs = %{
        name: String.trim(name),
        description: description,
        owner_id: owner_id,
        segment_id: segment_id,
        exclude_unsubscribed: exclude_unsubscribed,
        subject: subject,
        body_template_id: body_template_id,
        start_at: start_at,
        end_at: end_at,
        utm_source: utm_source,
        utm_medium: utm_medium,
        audience_size: length(audience),
        status: :scheduled,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Campaign.changeset(%Campaign{}, campaign_attrs)) do
        {:ok, campaign} ->
          Enum.each(audience, fn member ->
            delivery_attrs = %{
              campaign_id: campaign.id,
              recipient_id: member.id,
              recipient_email: member.email,
              status: :pending
            }

            Repo.insert!(CampaignDelivery.changeset(%CampaignDelivery{}, delivery_attrs))
          end)

          Scheduler.enqueue_campaign(campaign.id, start_at)

          Logger.info(
            "Campaign #{campaign.id} scheduled for #{start_at}, audience=#{length(audience)}"
          )

          {:ok, campaign}

        {:error, changeset} ->
          Logger.error("Campaign creation failed: #{inspect(changeset.errors)}")
          {:error, :launch_failed}
      end
    end
  end

  defp validate_name(name) do
    if is_binary(name) and String.length(String.trim(name)) >= 3 do
      :ok
    else
      {:error, :invalid_campaign_name}
    end
  end

  defp validate_subject(subject) do
    if is_binary(subject) and String.length(String.trim(subject)) >= 5 do
      :ok
    else
      {:error, :invalid_subject}
    end
  end

  defp validate_schedule(start_at, end_at) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(start_at, now) == :lt ->
        {:error, :start_at_in_past}

      not is_nil(end_at) and DateTime.compare(end_at, start_at) != :gt ->
        {:error, :end_at_before_start_at}

      true ->
        :ok
    end
  end
end
```
