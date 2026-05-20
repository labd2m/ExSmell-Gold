```elixir
defmodule Moderation.ContentReviewer do
  @moduledoc """
  Applies automated moderation decisions to flagged content items.
  Routes to immediate removal, human review, or escalation based on
  violation category and classifier confidence.
  """

  require Logger

  alias Moderation.{
    ContentStore,
    HumanReviewQueue,
    EscalationDesk,
    AuthorPenaltyEngine,
    NotificationSender,
    PolicyLog,
    AuditLog
  }

  @auto_action_confidence 0.92
  @escalation_confidence_floor 0.60

  def review(%Moderation.FlaggedContent{
        content_id: content_id,
        author_id: author_id,
        platform: platform,
        raw_content: raw_content,
        report_count: report_count,
        violation_category: :csam,
        confidence_score: confidence_score
      })
      when confidence_score >= @escalation_confidence_floor do
    Logger.warning(
      "[ContentReviewer] CSAM flag on content #{content_id} from #{author_id} " <>
        "on #{platform} (confidence: #{confidence_score}, reports: #{report_count})"
    )

    with :ok <- ContentStore.remove_immediately(content_id),
         {:ok, case_id} <- EscalationDesk.open_csam_case(content_id, author_id, raw_content),
         :ok <- AuthorPenaltyEngine.suspend(author_id, :permanent, :csam),
         :ok <- NotificationSender.alert_trust_and_safety(content_id, author_id, case_id),
         :ok <- PolicyLog.record(:csam_actioned, content_id, %{
                  author_id: author_id,
                  platform: platform,
                  case_id: case_id,
                  confidence_score: confidence_score
                }),
         :ok <- AuditLog.write(:content_removed_csam, author_id, %{
                  content_id: content_id,
                  case_id: case_id,
                  report_count: report_count
                }) do
      Logger.info("[ContentReviewer] CSAM content #{content_id} removed and case #{case_id} opened")
      {:ok, :removed_escalated, case_id}
    else
      {:error, reason} ->
        Logger.error("[ContentReviewer] CSAM action failed for #{content_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def review(%Moderation.FlaggedContent{
        content_id: content_id,
        author_id: author_id,
        platform: platform,
        raw_content: raw_content,
        report_count: report_count,
        violation_category: :hate_speech,
        confidence_score: confidence_score
      })
      when confidence_score >= @auto_action_confidence do
    Logger.info(
      "[ContentReviewer] High-confidence hate speech detected on #{content_id} " <>
        "(confidence: #{confidence_score})"
    )

    penalty = if report_count > 5, do: :temporary_ban, else: :content_removal_warning

    with :ok <- ContentStore.remove_immediately(content_id),
         :ok <- AuthorPenaltyEngine.apply(author_id, penalty, :hate_speech),
         :ok <- NotificationSender.send_author_strike(author_id, content_id, :hate_speech),
         :ok <- PolicyLog.record(:hate_speech_actioned, content_id, %{
                  author_id: author_id,
                  platform: platform,
                  penalty: penalty,
                  confidence_score: confidence_score,
                  raw_excerpt: String.slice(raw_content, 0, 200)
                }),
         :ok <- AuditLog.write(:content_removed_hate, author_id, %{
                  content_id: content_id,
                  report_count: report_count
                }) do
      {:ok, :removed, penalty}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def review(%Moderation.FlaggedContent{
        content_id: content_id,
        author_id: author_id,
        platform: platform,
        raw_content: _raw_content,
        report_count: report_count,
        violation_category: violation_category,
        confidence_score: confidence_score
      })
      when confidence_score >= @escalation_confidence_floor and
             confidence_score < @auto_action_confidence do
    Logger.info(
      "[ContentReviewer] Borderline #{violation_category} content #{content_id} " <>
        "(confidence: #{confidence_score}). Routing to human review."
    )

    priority = if report_count > 10, do: :high, else: :standard

    with {:ok, review_id} <-
           HumanReviewQueue.enqueue(content_id, violation_category, priority, author_id),
         :ok <- PolicyLog.record(:queued_for_review, content_id, %{
                  author_id: author_id,
                  platform: platform,
                  violation_category: violation_category,
                  confidence_score: confidence_score,
                  review_id: review_id
                }),
         :ok <- AuditLog.write(:content_queued_review, author_id, %{
                  content_id: content_id,
                  review_id: review_id,
                  priority: priority
                }) do
      {:ok, :queued_for_review, review_id}
    else
      {:error, reason} ->
        Logger.error("[ContentReviewer] Human queue enqueue failed for #{content_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def review(%Moderation.FlaggedContent{content_id: id, confidence_score: score})
      when score < @escalation_confidence_floor do
    Logger.debug("[ContentReviewer] Confidence #{score} below threshold for #{id}. No action taken.")
    {:ok, :no_action}
  end

  def review(%Moderation.FlaggedContent{content_id: id, violation_category: cat}) do
    Logger.warning("[ContentReviewer] No review rule for category '#{cat}' on content #{id}")
    {:error, :unhandled_violation_category}
  end
end
```
