```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches marketing and transactional notification campaigns
  across email, SMS, and push-notification channels.
  """

  require Logger

  alias Notifications.{
    Campaign, Recipient, Template,
    EmailAdapter, SMSAdapter, PushAdapter,
    DeliveryLog, MetricsCounter
  }

  @batch_size          200
  @default_send_window {8, 21}   # 08:00 – 21:00 local

  def send_campaign(%Campaign{} = campaign, opts \\ []) do
    simulate    = Keyword.get(opts, :simulate, false)
    force_send  = Keyword.get(opts, :force_send, false)
    caller_note = Keyword.get(opts, :note, "")

    Logger.info("Starting campaign #{campaign.id} — #{campaign.name}")

    # 1. Load and filter the target audience
    recipients =
      campaign.audience_segment
      |> Recipient.list_by_segment()
      |> Enum.filter(fn r ->
        r.active and (r.email != nil or r.phone != nil or r.push_token != nil)
      end)

    if recipients == [] do
      Logger.warning("Campaign #{campaign.id} has no eligible recipients.")
      {:ok, %{sent: 0, skipped: 0}}
    else
      # 2. Remove globally unsubscribed users
      unsubscribed_ids =
        recipients
        |> Enum.map(& &1.user_id)
        |> Recipient.filter_unsubscribed(campaign.channel)

      eligible = Enum.reject(recipients, &(&1.user_id in unsubscribed_ids))

      Logger.info("#{length(eligible)} eligible / #{length(unsubscribed_ids)} unsubscribed")

      # 3. Enforce send-window unless force_send is set
      {window_start, window_end} = @default_send_window
      current_hour = DateTime.utc_now().hour

      if not force_send and (current_hour < window_start or current_hour >= window_end) do
        Logger.info("Outside send window — campaign #{campaign.id} deferred.")
        {:deferred, :outside_send_window}
      else
        # 4. Load and compile the template
        template = Template.get!(campaign.template_id)

        # 5. Initialise metrics counters
        MetricsCounter.init(campaign.id, %{total: length(eligible), sent: 0, failed: 0})

        # 6. Dispatch in batches
        {sent, failed} =
          eligible
          |> Enum.chunk_every(@batch_size)
          |> Enum.reduce({0, 0}, fn batch, {sent_acc, failed_acc} ->
            batch_results =
              Enum.map(batch, fn recipient ->
                # Personalise the template for this recipient
                personalised =
                  Template.render(template, %{
                    first_name:   recipient.first_name,
                    last_name:    recipient.last_name,
                    unsubscribe:  "https://example.com/unsub/#{recipient.user_id}"
                  })

                # Route to the appropriate channel
                result =
                  cond do
                    campaign.channel == :email and recipient.email != nil ->
                      if simulate do
                        Logger.debug("SIMULATE email → #{recipient.email}")
                        {:ok, :simulated}
                      else
                        EmailAdapter.deliver(%{
                          to:      recipient.email,
                          subject: campaign.subject,
                          body:    personalised
                        })
                      end

                    campaign.channel == :sms and recipient.phone != nil ->
                      if simulate do
                        Logger.debug("SIMULATE sms → #{recipient.phone}")
                        {:ok, :simulated}
                      else
                        SMSAdapter.send(%{to: recipient.phone, body: personalised})
                      end

                    campaign.channel == :push and recipient.push_token != nil ->
                      if simulate do
                        Logger.debug("SIMULATE push → #{recipient.push_token}")
                        {:ok, :simulated}
                      else
                        PushAdapter.notify(%{
                          token:   recipient.push_token,
                          title:   campaign.subject,
                          body:    personalised
                        })
                      end

                    true ->
                      {:error, :no_channel_available}
                  end

                # Log individual delivery result
                status = if match?({:ok, _}, result), do: :delivered, else: :failed
                DeliveryLog.insert(%{
                  campaign_id:  campaign.id,
                  user_id:      recipient.user_id,
                  channel:      campaign.channel,
                  status:       status,
                  note:         caller_note,
                  delivered_at: DateTime.utc_now()
                })

                result
              end)

            batch_sent   = Enum.count(batch_results, &match?({:ok, _}, &1))
            batch_failed = length(batch_results) - batch_sent

            MetricsCounter.increment(campaign.id, :sent, batch_sent)
            MetricsCounter.increment(campaign.id, :failed, batch_failed)

            {sent_acc + batch_sent, failed_acc + batch_failed}
          end)

        Logger.info("Campaign #{campaign.id} complete — sent: #{sent}, failed: #{failed}")
        {:ok, %{sent: sent, failed: failed, skipped: length(unsubscribed_ids)}}
      end
    end
  end
end
```
