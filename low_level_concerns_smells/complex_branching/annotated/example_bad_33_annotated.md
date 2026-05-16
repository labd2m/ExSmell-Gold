# Annotated Example 33

- **Smell name:** Complex Branching
- **Expected smell location:** `dispatch_notification/2` function, the `case` expression over the notification provider response
- **Affected function(s):** `dispatch_notification/2`
- **Short explanation:** All delivery outcomes from a single notification API endpoint — sent, queued, invalid recipient, unsubscribed, bounced, throttled, provider errors, and network failures — are squeezed into one function via a large `case`, making the function hard to read and test scenario by scenario.

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches transactional notifications (email, SMS, push) through the
  unified NotifyHub provider API. Handles delivery receipts and failure logging.
  """

  require Logger

  alias Notifications.Repo
  alias Notifications.Schema.{NotificationLog, Subscriber}
  alias Notifications.NotifyHub.Client

  @channels [:email, :sms, :push]
  @retryable_errors [:throttled, :provider_timeout, :provider_unavailable]

  def send(subscriber_id, template_id, params, channel \\ :email)
      when channel in @channels do
    with {:ok, subscriber} <- fetch_subscriber(subscriber_id),
         :ok <- check_opted_in(subscriber, channel),
         {:ok, payload} <- build_payload(template_id, params, subscriber) do
      dispatch_notification(subscriber, Client.deliver(channel, payload))
    end
  end

  defp fetch_subscriber(subscriber_id) do
    case Repo.get(Subscriber, subscriber_id) do
      nil -> {:error, :subscriber_not_found}
      sub -> {:ok, sub}
    end
  end

  defp check_opted_in(%Subscriber{opted_out: true}, _channel), do: {:error, :opted_out}
  defp check_opted_in(_, _), do: :ok

  defp build_payload(template_id, params, subscriber) do
    case Notifications.Templates.render(template_id, params) do
      {:ok, body} -> {:ok, %{to: subscriber.contact, body: body}}
      {:error, _} = err -> err
    end
  end

  # VALIDATION: SMELL START - Complex Branching
  # VALIDATION: This is a smell because the function takes on full responsibility
  # for handling every possible response from the NotifyHub delivery endpoint,
  # using a single large case with many arms. Each branch represents a distinct
  # delivery scenario — success, queuing, various client and server errors — that
  # could be handled by dedicated helpers, keeping this function focused and short.
  defp dispatch_notification(subscriber, provider_response) do
    case provider_response do
      {:ok, %{status: 200, body: %{"message_id" => msg_id, "status" => "sent"}}} ->
        Logger.info("Notification sent to subscriber #{subscriber.id}, msg_id #{msg_id}")

        Repo.insert(%NotificationLog{
          subscriber_id: subscriber.id,
          message_id: msg_id,
          status: :sent
        })

        {:ok, :sent}

      {:ok, %{status: 202, body: %{"message_id" => msg_id, "status" => "queued"}}} ->
        Logger.info("Notification queued for subscriber #{subscriber.id}, msg_id #{msg_id}")

        Repo.insert(%NotificationLog{
          subscriber_id: subscriber.id,
          message_id: msg_id,
          status: :queued
        })

        {:ok, :queued}

      {:ok, %{status: 400, body: %{"error" => "invalid_recipient"}}} ->
        Logger.warning("Invalid recipient for subscriber #{subscriber.id}")

        Repo.insert(%NotificationLog{
          subscriber_id: subscriber.id,
          status: :failed,
          failure_reason: "invalid_recipient"
        })

        {:error, :invalid_recipient}

      {:ok, %{status: 400, body: %{"error" => "malformed_payload"}}} ->
        Logger.error("Malformed payload for subscriber #{subscriber.id}")
        {:error, :malformed_payload}

      {:ok, %{status: 410, body: %{"error" => "unsubscribed"}}} ->
        Logger.info("Subscriber #{subscriber.id} has unsubscribed, updating opt-out status")

        Subscriber.changeset(subscriber, %{opted_out: true})
        |> Repo.update()

        {:error, :unsubscribed}

      {:ok, %{status: 422, body: %{"error" => "bounced", "bounce_type" => type}}} ->
        Logger.warning("Notification bounced (#{type}) for subscriber #{subscriber.id}")

        Repo.insert(%NotificationLog{
          subscriber_id: subscriber.id,
          status: :bounced,
          failure_reason: "bounce:#{type}"
        })

        {:error, {:bounced, type}}

      {:ok, %{status: 429, body: %{"retry_after" => retry_after}}} ->
        Logger.warning("Throttled by NotifyHub for subscriber #{subscriber.id}, retry after #{retry_after}s")
        {:error, :throttled}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("NotifyHub unavailable for subscriber #{subscriber.id}")
        {:error, :provider_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected NotifyHub response #{status} for #{subscriber.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("NotifyHub timeout for subscriber #{subscriber.id}")
        {:error, :provider_timeout}

      {:error, reason} ->
        Logger.error("NotifyHub connection error for subscriber #{subscriber.id}: #{inspect(reason)}")
        {:error, {:provider_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  def retryable?({:error, reason}), do: reason in @retryable_errors
  def retryable?(_), do: false

  def bulk_send(subscriber_ids, template_id, params, channel \\ :email) do
    subscriber_ids
    |> Task.async_stream(&send(&1, template_id, params, channel),
      max_concurrency: 10,
      timeout: 5_000
    )
    |> Enum.to_list()
  end
end
```
