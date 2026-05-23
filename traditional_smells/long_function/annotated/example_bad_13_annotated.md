# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Notifications.DigestBuilder.build_and_send/2`
- **Affected function(s):** `build_and_send/2`
- **Short explanation:** The `build_and_send/2` function fetches unread notifications, groups them by category, formats per-category summaries, assembles the full digest payload, handles unsubscribe-token generation, renders the final email template, delivers it, and records the digest delivery — all inline with no extraction. It grossly violates single-responsibility.

---

```elixir
defmodule Notifications.DigestBuilder do
  @moduledoc """
  Builds and sends periodic notification digest emails to users,
  grouping activity by category and respecting unsubscribe preferences.
  """

  alias Notifications.{Notification, DigestLog, UnsubscribeToken, Repo}
  alias Integrations.Mailer
  alias UserManagement.User
  require Logger

  @max_items_per_category 5
  @digest_types [:daily, :weekly]

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `build_and_send/2` handles user/preference
  # VALIDATION: loading, unread notification fetching, category grouping, summary
  # VALIDATION: formatting, unsubscribe token generation, template rendering, email
  # VALIDATION: delivery, and delivery logging all in one excessively long function.
  def build_and_send(user_id, digest_type) when digest_type in @digest_types do
    Logger.info("Building #{digest_type} digest for user=#{user_id}")

    # --- Load user and preferences ---
    user = Repo.get!(User, user_id)

    unless user.digest_preference == digest_type do
      Logger.debug("User #{user_id} not subscribed to #{digest_type} digest, skipping")
      {:ok, :skipped}
    else
      # --- Compute lookback window ---
      since =
        case digest_type do
          :daily  -> DateTime.add(DateTime.utc_now(), -86_400, :second)
          :weekly -> DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
        end

      # --- Fetch unread notifications ---
      notifications =
        Notification
        |> Notification.for_user(user_id)
        |> Notification.unread()
        |> Notification.since(since)
        |> Notification.ordered_by_recency()
        |> Repo.all()

      if Enum.empty?(notifications) do
        Logger.info("No notifications for user #{user_id}, skipping digest")
        {:ok, :nothing_to_send}
      else
        # --- Group by category ---
        grouped =
          Enum.group_by(notifications, fn n ->
            n.category || "general"
          end)

        # --- Build per-category summaries (cap at max items) ---
        category_summaries =
          Enum.map(grouped, fn {category, items} ->
            trimmed = Enum.take(items, @max_items_per_category)
            overflow = length(items) - length(trimmed)

            lines =
              Enum.map(trimmed, fn n ->
                %{
                  title: n.title,
                  body: n.body,
                  url: n.action_url,
                  received_at: n.inserted_at
                }
              end)

            %{
              category: category,
              items: lines,
              total_count: length(items),
              overflow: overflow
            }
          end)
          |> Enum.sort_by(& &1.total_count, :desc)

        # --- Generate unsubscribe token ---
        raw_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        expires_at = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)

        Repo.insert!(%UnsubscribeToken{
          user_id: user_id,
          token: raw_token,
          digest_type: digest_type,
          expires_at: expires_at
        })

        base_url = Application.get_env(:notifications, :base_url, "https://app.example.com")
        unsubscribe_url = "#{base_url}/unsubscribe?token=#{raw_token}"

        # --- Render and send ---
        total_notifications = length(notifications)
        subject_prefix = if digest_type == :daily, do: "Your daily update", else: "Your weekly summary"
        subject = "#{subject_prefix}: #{total_notifications} new notification(s)"

        email_payload = %{
          to: user.email,
          subject: subject,
          template: "digest_#{digest_type}",
          assigns: %{
            user_name: user.full_name,
            digest_type: digest_type,
            total_count: total_notifications,
            categories: category_summaries,
            unsubscribe_url: unsubscribe_url,
            generated_at: DateTime.utc_now()
          }
        }

        case Mailer.send_templated(email_payload) do
          {:ok, ref} ->
            Repo.insert!(%DigestLog{
              user_id: user_id,
              digest_type: digest_type,
              notification_count: total_notifications,
              external_ref: ref,
              sent_at: DateTime.utc_now()
            })

            Logger.info("Digest sent to user #{user_id}, ref=#{ref}")
            {:ok, :sent}

          {:error, reason} ->
            Logger.error("Digest delivery failed for user #{user_id}: #{inspect(reason)}")
            {:error, reason}
        end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
