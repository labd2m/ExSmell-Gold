```elixir
defmodule ContentModerator do
  @moduledoc """
  Automated and manual content moderation for the platform.
  Reviews user posts, profile images, and appeal submissions from flagged users.
  """

  alias ContentModerator.{
    PostModerationRequest,
    ImageScanRequest,
    AppealRequest,
    PostStore,
    MediaStore,
    AppealStore,
    MLClassifier,
    ImageAnalyzer,
    ModerationLog,
    UserNotifier,
    ModeratorQueue
  }

  require Logger

  @doc """
  Review a content moderation event.

  Accepts a `%PostModerationRequest{}`, `%ImageScanRequest{}`, or
  `%AppealRequest{}` and performs the appropriate review action.

  ## Examples

      iex> ContentModerator.review(%PostModerationRequest{post_id: "p1", triggered_by: :report})
      {:ok, %{verdict: :removed, reason: :hate_speech}}

  """
  def review(%PostModerationRequest{
        post_id: post_id,
        triggered_by: triggered_by,
        reporter_id: reporter_id
      }) do
    with {:ok, post} <- PostStore.find(post_id),
         {:ok, classification} <-
           MLClassifier.classify_text(post.content, [:hate_speech, :spam, :harassment, :safe]),
         verdict = determine_post_verdict(classification),
         {:ok, updated_post} <- apply_post_verdict(post, verdict),
         :ok <-
           ModerationLog.record(%{
             resource_type: :post,
             resource_id: post_id,
             verdict: verdict,
             triggered_by: triggered_by,
             reporter_id: reporter_id,
             classification: classification,
             reviewed_at: DateTime.utc_now()
           }),
         :ok <- maybe_notify_post_author(updated_post, verdict) do
      Logger.info("Post #{post_id} reviewed: #{verdict}")
      {:ok, %{verdict: verdict, reason: classification.top_label}}
    end
  end

  # review profile image for inappropriate content
  def review(%ImageScanRequest{
        media_id: media_id,
        user_id: user_id,
        upload_context: context
      }) do
    with {:ok, media} <- MediaStore.find(media_id),
         {:ok, scan_result} <-
           ImageAnalyzer.scan(media.url, [:nudity, :violence, :hate_symbols, :safe]),
         :ok <- validate_scan_threshold(scan_result),
         {:ok, _} <- MediaStore.update(media_id, %{scan_status: :passed, scanned_at: DateTime.utc_now()}),
         :ok <-
           ModerationLog.record(%{
             resource_type: :image,
             resource_id: media_id,
             user_id: user_id,
             context: context,
             scan_result: scan_result,
             reviewed_at: DateTime.utc_now()
           }) do
      Logger.info("Image #{media_id} scanned clean for user #{user_id}")
      {:ok, %{media_id: media_id, status: :approved}}
    else
      {:error, :failed_threshold} ->
        MediaStore.update(media_id, %{scan_status: :rejected})
        UserNotifier.send_image_rejected(user_id, context)
        {:error, :image_rejected}

      error ->
        error
    end
  end

  # review appeal submitted by a user whose content was removed
  def review(%AppealRequest{
        appeal_id: appeal_id,
        original_action_id: action_id,
        user_statement: statement,
        submitted_at: submitted_at
      }) do
    with {:ok, appeal} <- AppealStore.find(appeal_id),
         {:ok, original_action} <- ModerationLog.find(action_id),
         :ok <- validate_appeal_window(submitted_at, original_action.reviewed_at),
         {:ok, _} <- AppealStore.update(appeal_id, %{status: :under_review}),
         :ok <-
           ModeratorQueue.enqueue_appeal(%{
             appeal_id: appeal_id,
             original_action: original_action,
             user_statement: statement,
             priority: compute_appeal_priority(original_action)
           }),
         :ok <- UserNotifier.send_appeal_received(appeal.user_id, appeal_id) do
      Logger.info("Appeal #{appeal_id} queued for human review")
      {:ok, %{appeal_id: appeal_id, status: :under_review}}
    end
  end

  defp determine_post_verdict(%{top_label: :safe}), do: :approved
  defp determine_post_verdict(%{top_label: :spam}), do: :hidden
  defp determine_post_verdict(%{top_label: _}), do: :removed

  defp apply_post_verdict(post, :removed), do: PostStore.update(post.id, %{status: :removed})
  defp apply_post_verdict(post, :hidden), do: PostStore.update(post.id, %{status: :hidden})
  defp apply_post_verdict(post, :approved), do: {:ok, post}

  defp maybe_notify_post_author(%{status: :removed} = post, _),
    do: UserNotifier.send_post_removed(post.author_id)

  defp maybe_notify_post_author(_, _), do: :ok

  defp validate_scan_threshold(%{scores: scores}) do
    safe_score = Map.get(scores, :safe, 0.0)
    if safe_score >= 0.85, do: :ok, else: {:error, :failed_threshold}
  end

  defp validate_appeal_window(submitted_at, reviewed_at) do
    hours_elapsed = DateTime.diff(submitted_at, reviewed_at, :hour)
    if hours_elapsed <= 72, do: :ok, else: {:error, :appeal_window_expired}
  end

  defp compute_appeal_priority(%{verdict: :removed}), do: :high
  defp compute_appeal_priority(%{verdict: :hidden}), do: :normal
  defp compute_appeal_priority(_), do: :low
end
```
