```elixir
defmodule Reviews.Moderation do
  @moduledoc """
  Handles the review submission and moderation workflow. Reviews pass through
  an automated content check before being stored. Those that fail automatic
  checks enter a manual review queue instead of being published directly.
  """

  alias MyApp.Repo
  alias Reviews.{Review, ModerationQueue}

  @type author_id :: String.t()
  @type subject_id :: String.t()
  @type submit_params :: %{
          author_id: author_id(),
          subject_id: subject_id(),
          body: String.t(),
          rating: 1..5
        }
  @type submit_result ::
          {:ok, :published, Review.t()}
          | {:ok, :pending_review, Review.t()}
          | {:error, Ecto.Changeset.t()}

  @min_body_length 20
  @max_body_length 2_000

  @doc """
  Submits a review. Passes it through automated content checks; publishes
  immediately on pass or routes to the moderation queue on failure.
  """
  @spec submit(submit_params()) :: submit_result()
  def submit(%{author_id: _, subject_id: _, body: body, rating: rating} = params)
      when is_binary(body) and rating in 1..5 do
    Repo.transaction(fn ->
      with :ok <- validate_body_length(body),
           {:ok, review} <- insert_review(params, :draft) do
        apply_moderation_outcome(review, body)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Approves a review that is pending manual moderation."
  @spec approve(Review.t()) :: {:ok, Review.t()} | {:error, :not_pending}
  def approve(%Review{status: "pending"} = review) do
    review |> Review.status_changeset("published") |> Repo.update()
  end

  def approve(%Review{}), do: {:error, :not_pending}

  @doc "Rejects and removes a review pending manual moderation."
  @spec reject(Review.t(), String.t()) :: {:ok, Review.t()} | {:error, :not_pending}
  def reject(%Review{status: "pending"} = review, reason) when is_binary(reason) do
    review |> Review.status_changeset("rejected") |> Repo.update()
  end

  def reject(%Review{}, _reason), do: {:error, :not_pending}

  defp validate_body_length(body) do
    len = String.length(body)

    cond do
      len < @min_body_length -> {:error, :review_body_too_short}
      len > @max_body_length -> {:error, :review_body_too_long}
      true -> :ok
    end
  end

  defp insert_review(params, initial_status) do
    %Review{}
    |> Review.creation_changeset(Map.put(params, :status, Atom.to_string(initial_status)))
    |> Repo.insert()
  end

  defp apply_moderation_outcome(review, body) do
    if passes_auto_check?(body) do
      {:ok, published} = review |> Review.status_changeset("published") |> Repo.update()
      {:published, published}
    else
      ModerationQueue.enqueue!(review.id)
      {:ok, pending} = review |> Review.status_changeset("pending") |> Repo.update()
      {:pending_review, pending}
    end
  end

  defp passes_auto_check?(body) do
    blocked_patterns = Application.get_env(:my_app, :blocked_review_patterns, [])
    Enum.all?(blocked_patterns, fn pattern -> not String.match?(body, pattern) end)
  end

  defp unwrap_transaction({:ok, {:published, review}}), do: {:ok, :published, review}
  defp unwrap_transaction({:ok, {:pending_review, review}}), do: {:ok, :pending_review, review}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
```
