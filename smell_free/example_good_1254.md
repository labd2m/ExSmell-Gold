```elixir
defmodule Publishing.Articles.DraftManager do
  @moduledoc """
  Manages the authoring lifecycle for article drafts.
  Drafts progress through explicit state transitions: draft → review → published.
  Each transition is validated and timestamped.
  """

  alias Publishing.Articles.{Draft, Revision, DraftRepository}

  @type transition_result :: {:ok, Draft.t()} | {:error, atom() | String.t()}

  @doc """
  Creates a new draft with initial content.
  """
  @spec create(String.t(), String.t(), map(), keyword()) :: {:ok, Draft.t()} | {:error, String.t()}
  def create(author_id, title, content, opts \\ [])
      when is_binary(author_id) and is_binary(title) and is_map(content) do
    repo = Keyword.get(opts, :repo, DraftRepository)

    with :ok <- validate_title(title),
         :ok <- validate_content(content),
         {:ok, draft} <- build_draft(author_id, title, content) do
      repo.insert(draft)
    end
  end

  @doc """
  Saves a new revision of an existing draft without changing its status.
  """
  @spec save_revision(String.t(), map(), keyword()) :: {:ok, Draft.t()} | {:error, atom()}
  def save_revision(draft_id, content, opts \\ [])
      when is_binary(draft_id) and is_map(content) do
    repo = Keyword.get(opts, :repo, DraftRepository)

    with {:ok, draft} <- repo.fetch(draft_id),
         :ok <- assert_editable(draft),
         :ok <- validate_content(content),
         revision = Revision.new(content, draft.revision_count + 1),
         {:ok, updated} <- repo.append_revision(draft.id, revision) do
      {:ok, updated}
    end
  end

  @doc """
  Submits a draft for editorial review.
  Only drafts in `:draft` status may be submitted.
  """
  @spec submit_for_review(String.t(), keyword()) :: transition_result()
  def submit_for_review(draft_id, opts \\ []) when is_binary(draft_id) do
    repo = Keyword.get(opts, :repo, DraftRepository)
    transition(draft_id, :draft, :in_review, repo)
  end

  @doc """
  Publishes a draft that has been approved during review.
  Only drafts in `:in_review` status may be published.
  """
  @spec publish(String.t(), keyword()) :: transition_result()
  def publish(draft_id, opts \\ []) when is_binary(draft_id) do
    repo = Keyword.get(opts, :repo, DraftRepository)
    transition(draft_id, :in_review, :published, repo)
  end

  @doc """
  Returns a draft to `:draft` status from `:in_review`, allowing further edits.
  """
  @spec return_to_draft(String.t(), String.t(), keyword()) :: transition_result()
  def return_to_draft(draft_id, reason, opts \\ [])
      when is_binary(draft_id) and is_binary(reason) do
    repo = Keyword.get(opts, :repo, DraftRepository)

    with {:ok, draft} <- repo.fetch(draft_id),
         :ok <- assert_status(draft, :in_review),
         {:ok, updated} <- repo.set_status(draft.id, :draft, %{return_reason: reason}) do
      {:ok, updated}
    end
  end

  defp transition(draft_id, expected_status, new_status, repo) do
    with {:ok, draft} <- repo.fetch(draft_id),
         :ok <- assert_status(draft, expected_status),
         {:ok, updated} <- repo.set_status(draft.id, new_status, %{transitioned_at: DateTime.utc_now()}) do
      {:ok, updated}
    end
  end

  defp assert_editable(%Draft{status: s}) when s in [:draft], do: :ok
  defp assert_editable(%Draft{status: status}), do: {:error, {:not_editable, status}}

  defp assert_status(%Draft{status: expected}, expected), do: :ok
  defp assert_status(%Draft{status: actual}, expected), do: {:error, {:wrong_status, expected, actual}}

  defp validate_title(title) when is_binary(title) and byte_size(title) >= 3, do: :ok
  defp validate_title(_), do: {:error, "title must be at least 3 characters"}

  defp validate_content(%{body: body}) when is_binary(body) and body != "", do: :ok
  defp validate_content(_), do: {:error, "content must include a non-empty body field"}

  defp build_draft(author_id, title, content) do
    {:ok,
     %Draft{
       id: Ecto.UUID.generate(),
       author_id: author_id,
       title: title,
       content: content,
       status: :draft,
       revision_count: 0,
       created_at: DateTime.utc_now(),
       updated_at: DateTime.utc_now()
     }}
  end
end
```
