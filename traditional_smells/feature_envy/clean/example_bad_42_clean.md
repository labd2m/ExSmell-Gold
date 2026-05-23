```elixir
defmodule Notifications.DigestComposer do
  @moduledoc """
  Assembles weekly and daily digest emails for the notification system.
  Each digest is built per subscriber and then handed off to the mailer
  for delivery via the configured SMTP adapter.
  """

  alias Notifications.{Digest, Subscriber, ArticleFeed, TopicRegistry}
  alias Notifications.DigestComposer.{Section, Footer}

  @max_articles_per_topic 5
  @default_locale         "en"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Builds a complete digest payload for a single subscriber ID.
  Returns `{:ok, digest}` or `{:error, reason}`.
  """
  @spec compose(String.t()) :: {:ok, Digest.t()} | {:error, term()}
  def compose(subscriber_id) do
    with {:ok, subscriber} <- Subscriber.fetch(subscriber_id),
         :active           <- Subscriber.subscription_status(subscriber),
         sections          <- build_sections(subscriber),
         footer            <- build_footer(subscriber) do
      digest = %Digest{
        to:         subscriber.email,
        subject:    digest_subject(subscriber),
        sections:   sections,
        footer:     footer,
        locale:     subscriber.locale || @default_locale,
        created_at: DateTime.utc_now()
      }
      {:ok, digest}
    else
      :inactive -> {:error, :subscriber_inactive}
      error     -> error
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp build_sections(subscriber) do
    subscriber
    |> Subscriber.active_topics()
    |> Enum.map(&build_topic_section(subscriber, &1))
    |> Enum.reject(&Section.empty?/1)
  end

  defp build_topic_section(subscriber, topic) do
    articles = ArticleFeed.recent_for_topic(topic, limit: @max_articles_per_topic)
    label    = TopicRegistry.display_label(topic, subscriber.locale || @default_locale)
    %Section{topic: topic, label: label, articles: articles}
  end

  defp compose_subscriber_section(subscriber) do
    preferences   = Subscriber.get_preferences(subscriber)
    active_topics = Subscriber.active_topics(subscriber)
    frequency     = Subscriber.digest_frequency(subscriber)
    unsub_token   = Subscriber.unsubscribe_token(subscriber)

    greeting =
      case subscriber.full_name do
        nil  -> "Hello,"
        name -> "Hi #{String.split(name, " ") |> List.first()},"
      end

    topic_labels =
      active_topics
      |> Enum.map(&TopicRegistry.display_label(&1, subscriber.locale || @default_locale))
      |> Enum.join(", ")

    %{
      email:            subscriber.email,
      greeting:         greeting,
      locale:           subscriber.locale || @default_locale,
      tier:             subscriber.tier,
      topic_summary:    topic_labels,
      frequency_label:  frequency_display(frequency),
      show_images:      Map.get(preferences, :show_images, true),
      joined_since:     format_joined_date(subscriber.joined_at),
      unsubscribe_url:  build_unsub_url(unsub_token)
    }
  end

  defp build_footer(subscriber) do
    section = compose_subscriber_section(subscriber)
    %Footer{
      unsubscribe_url: section.unsubscribe_url,
      locale:          section.locale,
      joined_since:    section.joined_since
    }
  end

  defp digest_subject(subscriber) do
    locale = subscriber.locale || @default_locale
    case locale do
      "pt" -> "Seu resumo semanal está pronto"
      "es" -> "Tu resumen semanal está listo"
      _    -> "Your weekly digest is ready"
    end
  end

  defp frequency_display(:daily),  do: "daily"
  defp frequency_display(:weekly), do: "weekly"
  defp frequency_display(other),   do: Atom.to_string(other)

  defp format_joined_date(%Date{} = d),       do: Calendar.strftime(d, "%B %Y")
  defp format_joined_date(%DateTime{} = dt),  do: Calendar.strftime(dt, "%B %Y")
  defp format_joined_date(nil),               do: nil

  defp build_unsub_url(token) do
    base = Application.fetch_env!(:notifications, :base_url)
    "#{base}/unsubscribe?token=#{token}"
  end
end
```
