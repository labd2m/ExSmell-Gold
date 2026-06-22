```elixir
defmodule Publishing.ArticleWorkflow do
  @moduledoc """
  Manages the editorial state machine for article content.

  Articles progress through a defined set of statuses:
  `:draft` → `:in_review` → `:approved` → `:published` → `:archived`.

  Each transition is an explicit function with its own precondition
  guards and side-effect hooks. Invalid transitions return structured
  errors rather than raising exceptions.
  """

  alias Publishing.Article
  alias Publishing.ArticleStore
  alias Publishing.ContentIndex
  alias Publishing.NotificationBus

  @type transition_result ::
          {:ok, Article.t()}
          | {:error, :invalid_transition, atom(), atom()}
          | {:error, :persistence_failed}

  @doc """
  Submits a draft article for editorial review.
  """
  @spec submit_for_review(Article.t()) :: transition_result()
  def submit_for_review(%Article{status: :draft} = article) do
    transition(article, :in_review, fn updated ->
      NotificationBus.publish(:article_submitted, %{article_id: updated.id})
    end)
  end

  def submit_for_review(%Article{status: current}),
    do: {:error, :invalid_transition, current, :in_review}

  @doc """
  Approves an article that is currently under review.
  """
  @spec approve(Article.t(), String.t()) :: transition_result()
  def approve(%Article{status: :in_review} = article, reviewer_id)
      when is_binary(reviewer_id) do
    attrs = %{status: :approved, approved_by: reviewer_id, approved_at: DateTime.utc_now()}

    case ArticleStore.update(article, attrs) do
      {:ok, updated} ->
        NotificationBus.publish(:article_approved, %{article_id: updated.id, reviewer_id: reviewer_id})
        {:ok, updated}

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  def approve(%Article{status: current}, _reviewer_id),
    do: {:error, :invalid_transition, current, :approved}

  @doc """
  Publishes an approved article, making it publicly visible.
  """
  @spec publish(Article.t()) :: transition_result()
  def publish(%Article{status: :approved} = article) do
    attrs = %{status: :published, published_at: DateTime.utc_now()}

    with {:ok, updated} <- ArticleStore.update(article, attrs),
         :ok <- ContentIndex.index(updated) do
      NotificationBus.publish(:article_published, %{article_id: updated.id})
      {:ok, updated}
    else
      {:error, :index_failed} -> {:error, :persistence_failed}
      {:error, _} -> {:error, :persistence_failed}
    end
  end

  def publish(%Article{status: current}),
    do: {:error, :invalid_transition, current, :published}

  @doc """
  Archives a published article, removing it from active listings.
  """
  @spec archive(Article.t()) :: transition_result()
  def archive(%Article{status: :published} = article) do
    transition(article, :archived, fn updated ->
      ContentIndex.deindex(updated.id)
      NotificationBus.publish(:article_archived, %{article_id: updated.id})
    end)
  end

  def archive(%Article{status: current}),
    do: {:error, :invalid_transition, current, :archived}

  @doc """
  Resets an in-review article back to draft for further editing.
  """
  @spec reject_to_draft(Article.t(), String.t()) :: transition_result()
  def reject_to_draft(%Article{status: :in_review} = article, reason)
      when is_binary(reason) do
    attrs = %{status: :draft, rejection_reason: reason}

    case ArticleStore.update(article, attrs) do
      {:ok, updated} ->
        NotificationBus.publish(:article_rejected, %{article_id: updated.id, reason: reason})
        {:ok, updated}

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  def reject_to_draft(%Article{status: current}, _reason),
    do: {:error, :invalid_transition, current, :draft}

  @spec transition(Article.t(), atom(), (Article.t() -> term())) :: transition_result()
  defp transition(article, new_status, after_fn) do
    case ArticleStore.update(article, %{status: new_status}) do
      {:ok, updated} ->
        after_fn.(updated)
        {:ok, updated}

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end
end
```
