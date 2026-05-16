# Annotated Example 24

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Content.PublishingPipeline.publish/2`, lines where `content` map keys are accessed dynamically
- **Affected function(s):** `publish/2`
- **Short explanation:** `content[:title]`, `content[:body]`, `content[:author_id]`, and `content[:scheduled_at]` use dynamic bracket access. When `:body` is absent, `nil` is passed to `String.length/1` inside the word-count helper, raising a `FunctionClauseError`. A missing `:scheduled_at` silently publishes content immediately instead of at the intended future time.

---

```elixir
defmodule Content.PublishingPipeline do
  @moduledoc """
  Validates, enriches, and publishes content items (articles, blog posts,
  announcements) through a multi-step publishing pipeline.
  """

  require Logger

  @max_title_length 160
  @min_body_words   50
  @max_body_chars   50_000

  @type content_item :: %{optional(atom()) => term()}

  @type published_item :: %{
          id: String.t(),
          title: String.t(),
          slug: String.t(),
          author_id: String.t(),
          word_count: integer(),
          published_at: DateTime.t(),
          scheduled: boolean(),
          tags: list(String.t()),
          status: :published | :scheduled
        }

  @spec publish(content_item(), map()) ::
          {:ok, published_item()} | {:error, list(String.t())}
  def publish(content, pipeline_opts \\ %{}) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `content[:title]`, `content[:body]`,
    # `content[:author_id]`, and `content[:scheduled_at]` use dynamic bracket
    # access on a plain map. When `:body` is absent, `nil` flows into
    # `word_count/1`, which calls `String.split(nil, ...)`, immediately
    # raising `FunctionClauseError`. When `:scheduled_at` is absent, `nil`
    # is treated as falsy and the item is published immediately instead of
    # being queued for future delivery, with no indication of the missing key.
    title        = content[:title]
    body         = content[:body]
    author_id    = content[:author_id]
    scheduled_at = content[:scheduled_at]
    # VALIDATION: SMELL END

    tags = Map.get(content, :tags, [])

    errors =
      []
      |> validate_title(title)
      |> validate_body(body)
      |> validate_author(author_id)
      |> validate_scheduled_at(scheduled_at)

    if errors == [] do
      slug         = slugify(title)
      wc           = word_count(body)
      now          = DateTime.utc_now()
      publish_time = scheduled_at || now
      status       = if scheduled_at, do: :scheduled, else: :published

      item = %{
        id: generate_id(),
        title: title,
        slug: slug,
        author_id: author_id,
        word_count: wc,
        published_at: publish_time,
        scheduled: status == :scheduled,
        tags: tags,
        status: status
      }

      run_post_publish_hooks(item, pipeline_opts)

      Logger.info("Content published",
        id: item.id,
        slug: slug,
        author_id: author_id,
        status: status,
        word_count: wc
      )

      {:ok, item}
    else
      {:error, errors}
    end
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_title(errors, nil),   do: ["Title is required" | errors]
  defp validate_title(errors, title) do
    cond do
      String.trim(title) == ""            -> ["Title must not be blank" | errors]
      String.length(title) > @max_title_length ->
        ["Title exceeds #{@max_title_length} characters" | errors]
      true -> errors
    end
  end

  defp validate_body(errors, nil),  do: ["Body is required" | errors]
  defp validate_body(errors, body) do
    cond do
      String.length(body) > @max_body_chars ->
        ["Body exceeds #{@max_body_chars} characters" | errors]
      word_count(body) < @min_body_words ->
        ["Body must contain at least #{@min_body_words} words" | errors]
      true -> errors
    end
  end

  defp validate_author(errors, nil), do: ["Author ID is required" | errors]
  defp validate_author(errors, _),   do: errors

  defp validate_scheduled_at(errors, nil), do: errors
  defp validate_scheduled_at(errors, dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      errors
    else
      ["Scheduled time must be in the future" | errors]
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp word_count(body) do
    body |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

  defp run_post_publish_hooks(item, opts) do
    if Map.get(opts, :notify_subscribers, false) do
      Logger.debug("Notifying subscribers for #{item.slug}")
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
```
