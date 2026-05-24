```elixir
defmodule MyApp.Marketing.CampaignLauncher do
  @moduledoc """
  Orchestrates the launch of email marketing campaigns.
  Handles audience resolution, A/B test splitting, send-window enforcement,
  and suppression list application.
  """

  alias MyApp.Marketing.{EmailCampaign, AudienceSegment, CampaignRun}
  alias MyApp.Email.{TemplateRenderer, BatchSender}
  alias MyApp.Contacts.{ContactResolver, SuppressionList}

  @batch_size 250

  def launch(campaign_id) do
    with {:ok, campaign} <- EmailCampaign.fetch(campaign_id),
         {:ok, segment}  <- AudienceSegment.fetch(campaign.segment_id) do

      template_id       = campaign.template_id
      send_window       = campaign.send_window
      ab_test_config    = campaign.ab_test_config

      filter_criteria   = segment.filter_criteria
      suppression_id    = segment.suppression_list_id
      estimated_size    = segment.estimated_size

      now = DateTime.utc_now()
      unless within_send_window?(now, send_window) do
        {:error, :outside_send_window}
      else
        run = %{
          id:          generate_id(),
          campaign_id: campaign_id,
          started_at:  now,
          status:      :running,
          sent:        0,
          skipped:     0
        }
        CampaignRun.save(run)

        contacts      = ContactResolver.resolve(filter_criteria)
        suppressed    = SuppressionList.load(suppression_id)
        eligible      = Enum.reject(contacts, &(&1.email in suppressed))

        {group_a, group_b} = ab_split(eligible, ab_test_config)

        variant_a = Map.get(ab_test_config || %{}, :variant_a, template_id)
        variant_b = Map.get(ab_test_config || %{}, :variant_b, template_id)

        sent_a = send_to_group(group_a, variant_a, campaign_id)
        sent_b = send_to_group(group_b, variant_b, campaign_id)

        total_sent   = sent_a + sent_b
        total_skip   = estimated_size - total_sent

        finished = %{run |
          status:      :completed,
          sent:        total_sent,
          skipped:     max(total_skip, 0),
          completed_at: DateTime.utc_now()
        }
        CampaignRun.save(finished)
        {:ok, finished}
      end
    end
  end

  def cancel(campaign_id) do
    case CampaignRun.latest_for(campaign_id) do
      nil               -> {:error, :no_run_found}
      %{status: :completed} -> {:error, :already_completed}
      run ->
        CampaignRun.save(%{run | status: :cancelled, cancelled_at: DateTime.utc_now()})
        {:ok, :cancelled}
    end
  end

  def stats(campaign_id) do
    CampaignRun.list_for(campaign_id)
  end


  defp within_send_window?(now, nil), do: true
  defp within_send_window?(now, %{start: s, stop: e}) do
    DateTime.compare(now, s) != :lt and DateTime.compare(now, e) != :gt
  end

  defp ab_split(contacts, nil), do: {contacts, []}
  defp ab_split(contacts, %{split_percent: pct}) do
    count = floor(length(contacts) * pct / 100)
    Enum.split(contacts, count)
  end
  defp ab_split(contacts, _), do: {contacts, []}

  defp send_to_group([], _template_id, _campaign_id), do: 0
  defp send_to_group(contacts, template_id, campaign_id) do
    contacts
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      messages = Enum.map(batch, fn c ->
        {:ok, body} = TemplateRenderer.render(template_id, %{contact: c})
        %{to: c.email, body: body, campaign_id: campaign_id}
      end)
      {:ok, count} = BatchSender.send_batch(messages)
      acc + count
    end)
  end

  defp generate_id do
    "CRN-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
