```elixir
defmodule Moderation.PostModerationService do
  alias Moderation.{Repo, Post, Moderator, Classifier, RuleEngine, ModerationDecision, AuditLog}

  require Logger

  @classifier_threshold 0.75

  def moderate_post(post_id, moderator_id) do
    with {:ok, post} <- fetch_pending_post(post_id),
         {:ok, moderator} <- fetch_authorized_moderator(moderator_id),
         {:ok, classifier_result} <- Classifier.analyze(post.content, post.media_urls),
         {:ok, rule_result} <- RuleEngine.apply(post, classifier_result),
         {:ok, decision} <- persist_decision(post, moderator, classifier_result, rule_result) do
      post
      |> Post.changeset(%{
        moderation_status: decision.action,
        moderated_at: DateTime.utc_now(),
        moderated_by: moderator_id
      })
      |> Repo.update()

      AuditLog.record(:post_moderated, %{
        post_id: post_id,
        moderator_id: moderator_id,
        action: decision.action,
        reasons: decision.reasons
      })

      Logger.info(
        "Post #{post_id} moderated by #{moderator_id}: action=#{decision.action}"
      )

      {:ok, decision}
    else
      {:error, :post_not_found} ->
        Logger.warning("Post #{post_id} not found for moderation")
        {:error, :post_not_found}

      {:error, :already_moderated} ->
        Logger.info("Post #{post_id} has already been moderated")
        {:error, :post_already_moderated}

      {:error, :moderator_not_found} ->
        Logger.warning("Moderator #{moderator_id} not found")
        {:error, :moderator_not_found}

      {:error, :insufficient_permissions} ->
        Logger.warning("Moderator #{moderator_id} lacks permission to moderate post #{post_id}")
        {:error, :access_denied}

      {:error, :classifier_unavailable} ->
        Logger.error("Classifier service unavailable for post #{post_id}")
        {:error, :classifier_error}

      {:error, {:classifier_error, reason}} ->
        Logger.error("Classifier failed for post #{post_id}: #{inspect(reason)}")
        {:error, :classifier_error}

      {:error, :rule_conflict} ->
        Logger.warning("Conflicting rules for post #{post_id} — manual review required")
        {:error, :rule_conflict}

      {:error, :rule_engine_error} ->
        Logger.error("Rule engine failure for post #{post_id}")
        {:error, :rule_engine_error}

      {:error, :decision_record_failed} ->
        Logger.error("Could not persist moderation decision for post #{post_id}")
        {:error, :persistence_failed}
    end
  end

  defp fetch_pending_post(post_id) do
    case Repo.get(Post, post_id) do
      nil -> {:error, :post_not_found}
      %Post{moderation_status: status} when status != :pending -> {:error, :already_moderated}
      post -> {:ok, post}
    end
  end

  defp fetch_authorized_moderator(moderator_id) do
    case Repo.get(Moderator, moderator_id) do
      nil -> {:error, :moderator_not_found}
      %Moderator{active: false} -> {:error, :moderator_not_found}
      %Moderator{role: role} when role not in [:moderator, :senior_moderator, :admin] ->
        {:error, :insufficient_permissions}
      moderator -> {:ok, moderator}
    end
  end

  defp persist_decision(post, moderator, classifier_result, rule_result) do
    action = reconcile_action(classifier_result, rule_result)

    %ModerationDecision{}
    |> ModerationDecision.changeset(%{
      post_id: post.id,
      moderator_id: moderator.id,
      action: action,
      classifier_score: classifier_result.score,
      reasons: rule_result.triggered_rules,
      decided_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, d} -> {:ok, d}
      {:error, _} -> {:error, :decision_record_failed}
    end
  end

  defp reconcile_action(%{score: score}, %{recommended_action: rule_action})
       when score >= @classifier_threshold do
    rule_action
  end

  defp reconcile_action(_, _), do: :approved
end
```
