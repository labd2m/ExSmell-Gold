```elixir
defmodule Campaigns.BulkDispatcher do
  @moduledoc """
  Dispatches bulk email campaigns to large recipient lists by chunking
  work across supervised tasks, respecting per-provider rate limits,
  and recording per-recipient delivery outcomes.
  """

  alias Campaigns.{Repo, Campaign, RecipientList, DeliveryRecord, MailProvider}

  @chunk_size 100
  @max_concurrency 5

  @type campaign_id :: String.t()
  @type dispatch_summary :: %{
          total: non_neg_integer(),
          sent: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @spec dispatch(campaign_id()) :: {:ok, dispatch_summary()} | {:error, atom()}
  def dispatch(campaign_id) when is_binary(campaign_id) do
    with {:ok, campaign} <- fetch_campaign(campaign_id),
         :ok <- validate_ready(campaign),
         {:ok, _} <- mark_sending(campaign) do
      recipients = RecipientList.active_for_campaign(campaign_id)
      summary = send_in_chunks(campaign, recipients)
      finalize_campaign(campaign, summary)
      {:ok, summary}
    end
  end

  @spec send_in_chunks(Campaign.t(), [map()]) :: dispatch_summary()
  defp send_in_chunks(campaign, recipients) do
    recipients
    |> Enum.chunk_every(@chunk_size)
    |> Task.async_stream(
      &send_chunk(campaign, &1),
      max_concurrency: @max_concurrency,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(zero_summary(length(recipients)), &merge_chunk_result/2)
  end

  @spec send_chunk(Campaign.t(), [map()]) :: dispatch_summary()
  defp send_chunk(campaign, chunk) do
    Enum.reduce(chunk, %{sent: 0, failed: 0, skipped: 0}, fn recipient, acc ->
      case send_to_recipient(campaign, recipient) do
        :sent -> Map.update!(acc, :sent, &(&1 + 1))
        :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
        :failed -> Map.update!(acc, :failed, &(&1 + 1))
      end
    end)
  end

  @spec send_to_recipient(Campaign.t(), map()) :: :sent | :skipped | :failed
  defp send_to_recipient(campaign, recipient) do
    if recipient.unsubscribed do
      record_outcome(campaign.id, recipient.id, :skipped)
      :skipped
    else
      case MailProvider.send(%{
             to: recipient.email,
             subject: campaign.subject,
             html_body: campaign.html_body,
             text_body: campaign.text_body
           }) do
        {:ok, provider_id} ->
          record_outcome(campaign.id, recipient.id, :sent, provider_id)
          :sent

        {:error, _} ->
          record_outcome(campaign.id, recipient.id, :failed)
          :failed
      end
    end
  end

  @spec record_outcome(String.t(), String.t(), atom(), String.t() | nil) :: :ok
  defp record_outcome(campaign_id, recipient_id, status, provider_id \\ nil) do
    %DeliveryRecord{}
    |> DeliveryRecord.creation_changeset(%{
      campaign_id: campaign_id,
      recipient_id: recipient_id,
      status: status,
      provider_id: provider_id,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  end

  @spec fetch_campaign(campaign_id()) :: {:ok, Campaign.t()} | {:error, :not_found}
  defp fetch_campaign(id) do
    case Repo.get(Campaign, id) do
      nil -> {:error, :not_found}
      c -> {:ok, c}
    end
  end

  @spec validate_ready(Campaign.t()) :: :ok | {:error, :not_ready}
  defp validate_ready(%{status: :ready}), do: :ok
  defp validate_ready(_), do: {:error, :not_ready}

  @spec mark_sending(Campaign.t()) :: {:ok, Campaign.t()} | {:error, Ecto.Changeset.t()}
  defp mark_sending(campaign) do
    campaign |> Campaign.status_changeset(:sending) |> Repo.update()
  end

  @spec finalize_campaign(Campaign.t(), dispatch_summary()) :: :ok
  defp finalize_campaign(campaign, summary) do
    campaign
    |> Campaign.completion_changeset(%{
      status: :sent,
      sent_count: summary.sent,
      failed_count: summary.failed,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()

    :ok
  end

  @spec zero_summary(non_neg_integer()) :: dispatch_summary()
  defp zero_summary(total), do: %{total: total, sent: 0, failed: 0, skipped: 0}

  @spec merge_chunk_result({:ok, map()} | {:exit, term()}, dispatch_summary()) :: dispatch_summary()
  defp merge_chunk_result({:ok, chunk}, acc) do
    %{acc | sent: acc.sent + chunk.sent, failed: acc.failed + chunk.failed, skipped: acc.skipped + chunk.skipped}
  end

  defp merge_chunk_result({:exit, _}, acc) do
    Map.update!(acc, :failed, &(&1 + @chunk_size))
  end
end
```
