# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Marketing.CampaignLauncher.launch/1`, where optional campaign targeting fields are accessed dynamically
- **Affected function(s):** `launch/1`
- **Short explanation:** The function reads `:segment_id`, `:ab_test_variant`, and `:send_limit` from the campaign map using bracket access. Absent keys return `nil`, so campaigns are launched without audience segmentation (reaching all users), A/B split logic silently defaults to a single variant, and send limits are ignored — all without any error or warning.

```elixir
defmodule Marketing.CampaignLauncher do
  @moduledoc """
  Orchestrates the launch of email marketing campaigns.
  Handles audience segmentation, A/B test variant assignment,
  send-rate limiting, and delivery scheduling across time zones.
  """

  require Logger

  @supported_channels   [:email, :sms, :push, :in_app]
  @max_send_rate_per_min 5_000
  @ab_variants          [:a, :b, :c]

  @type campaign :: %{
          id: String.t(),
          name: String.t(),
          channel: atom(),
          template_id: String.t(),
          scheduled_at: DateTime.t(),
          created_by: String.t(),
          optional(:segment_id) => String.t(),
          optional(:ab_test_variant) => :a | :b | :c,
          optional(:send_limit) => pos_integer(),
          optional(:suppress_unsubscribed) => boolean()
        }

  @spec launch(campaign()) :: {:ok, map()} | {:error, String.t()}
  def launch(campaign) do
    with :ok <- validate_channel(campaign),
         :ok <- validate_schedule(campaign),
         :ok <- validate_ab_variant(campaign),
         {:ok, audience} <- resolve_audience(campaign),
         {:ok, result}   <- submit_to_queue(campaign, audience) do
      Logger.info("Campaign #{campaign.id} (#{campaign.name}) launched with #{result.recipient_count} recipients")
      {:ok, result}
    end
  end

  defp validate_channel(%{channel: ch}) when ch in @supported_channels, do: :ok
  defp validate_channel(%{channel: ch}), do: {:error, "unsupported channel: #{ch}"}

  defp validate_schedule(%{scheduled_at: dt}) do
    if DateTime.compare(dt, DateTime.utc_now()) == :lt do
      {:error, "scheduled_at is in the past"}
    else
      :ok
    end
  end

  defp validate_ab_variant(campaign) do
    case campaign[:ab_test_variant] do
      nil     -> :ok
      variant when variant in @ab_variants -> :ok
      variant -> {:error, "invalid ab_test_variant: #{variant}"}
    end
  end

  defp resolve_audience(campaign) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `campaign[:segment_id]`,
    # `campaign[:send_limit]`, and `campaign[:suppress_unsubscribed]` use dynamic
    # bracket access on a plain map. When `:segment_id` is absent, `nil` is returned
    # and `fetch_segment(nil)` is called, silently resolving to the full user base
    # instead of raising a data error. A missing `:send_limit` makes the cap check
    # always false (nil < integer is false), so unlimited sends proceed unchecked.
    # A missing `:suppress_unsubscribed` is treated as false, meaning unsubscribed
    # users may be included in the send — a legal compliance risk.
    segment_id           = campaign[:segment_id]
    send_limit           = campaign[:send_limit]
    suppress_unsubscribed = campaign[:suppress_unsubscribed]
    # VALIDATION: SMELL END

    ab_variant = campaign[:ab_test_variant]

    raw_audience    = fetch_segment(segment_id)
    filtered        = if suppress_unsubscribed, do: remove_unsubscribed(raw_audience), else: raw_audience
    variant_audience = if ab_variant, do: filter_by_variant(filtered, ab_variant), else: filtered

    final_audience =
      if send_limit && length(variant_audience) > send_limit do
        Logger.info("Applying send limit: #{send_limit} of #{length(variant_audience)} recipients")
        Enum.take(variant_audience, send_limit)
      else
        variant_audience
      end

    if final_audience == [] do
      {:error, "resolved audience is empty"}
    else
      {:ok, final_audience}
    end
  end

  defp fetch_segment(nil),        do: simulated_full_user_base()
  defp fetch_segment(segment_id), do: simulated_segment(segment_id)

  defp simulated_full_user_base do
    Enum.map(1..1_000, fn i ->
      %{user_id: "user_#{i}", email: "user#{i}@example.com", subscribed: rem(i, 10) != 0}
    end)
  end

  defp simulated_segment(segment_id) do
    Enum.map(1..200, fn i ->
      %{user_id: "seg_#{segment_id}_#{i}", email: "seg#{i}@example.com", subscribed: true}
    end)
  end

  defp remove_unsubscribed(audience), do: Enum.filter(audience, & &1.subscribed)
  defp filter_by_variant(audience, variant) do
    Enum.filter(audience, fn u ->
      hash = :erlang.phash2(u.user_id, length(@ab_variants))
      Enum.at(@ab_variants, hash) == variant
    end)
  end

  defp submit_to_queue(campaign, audience) do
    send_rate = min(@max_send_rate_per_min, length(audience))

    result = %{
      campaign_id:      campaign.id,
      template_id:      campaign.template_id,
      channel:          campaign.channel,
      recipient_count:  length(audience),
      send_rate_per_min: send_rate,
      scheduled_at:     campaign.scheduled_at,
      queued_at:        DateTime.utc_now()
    }

    {:ok, result}
  end
end
```
