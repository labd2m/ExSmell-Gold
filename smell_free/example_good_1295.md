```elixir
defmodule Digests.EmailDigestBuilder do
  @moduledoc """
  Assembles personalised email digests for users from accumulated activity records.

  Digest assembly is broken into fetching, grouping, scoring, and rendering
  stages. Each stage is a pure function, making the pipeline straightforward
  to test and extend.
  """

  alias Digests.EmailDigestBuilder.{
    ActivityFetcher,
    ActivityGrouper,
    RelevanceScorer,
    DigestRenderer,
    DigestRecord
  }

  @doc """
  Builds a digest for a user over the given time window.

  Returns `{:ok, digest}` with the rendered content, or `{:error, reason}`.
  """
  @spec build(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, DigestRecord.t()} | {:error, String.t()}
  def build(user_id, from_dt, to_dt, opts \\ [])
      when is_binary(user_id) do
    with {:ok, activities} <- ActivityFetcher.fetch(user_id, from_dt, to_dt),
         :ok <- check_non_empty(activities, user_id) do
      grouped = ActivityGrouper.group(activities)
      scored = RelevanceScorer.score(grouped, opts)
      rendered = DigestRenderer.render(user_id, scored, from_dt, to_dt)
      {:ok, rendered}
    end
  end

  defp check_non_empty([], user_id),
    do: {:error, "no activities for user #{user_id} in window"}

  defp check_non_empty(_, _), do: :ok
end

defmodule Digests.EmailDigestBuilder.ActivityGrouper do
  @moduledoc "Groups flat activity records into typed category buckets."

  @spec group([map()]) :: %{atom() => [map()]}
  def group(activities) when is_list(activities) do
    activities
    |> Enum.group_by(&categorise/1)
    |> Map.new(fn {cat, items} ->
      {cat, Enum.sort_by(items, & &1.occurred_at, DateTime)}
    end)
  end

  defp categorise(%{type: "comment"}), do: :comments
  defp categorise(%{type: "mention"}), do: :mentions
  defp categorise(%{type: "like"}), do: :likes
  defp categorise(%{type: "follow"}), do: :follows
  defp categorise(_), do: :other
end

defmodule Digests.EmailDigestBuilder.RelevanceScorer do
  @moduledoc "Scores and trims activity groups to surface the most relevant items."

  @category_limits %{mentions: 5, comments: 10, likes: 3, follows: 5, other: 3}
  @category_weights %{mentions: 10, comments: 5, likes: 1, follows: 3, other: 1}

  @spec score(%{atom() => [map()]}, keyword()) :: [%{category: atom(), items: [map()], score: number()}]
  def score(grouped, _opts) do
    grouped
    |> Enum.map(fn {category, items} ->
      limit = Map.get(@category_limits, category, 3)
      weight = Map.get(@category_weights, category, 1)
      trimmed = Enum.take(items, limit)
      %{category: category, items: trimmed, score: length(trimmed) * weight}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reject(&(&1.items == []))
  end
end

defmodule Digests.EmailDigestBuilder.DigestRenderer do
  @moduledoc "Renders a structured digest into an HTML and text body pair."

  alias Digests.EmailDigestBuilder.DigestRecord

  @spec render(String.t(), [map()], DateTime.t(), DateTime.t()) :: DigestRecord.t()
  def render(user_id, scored_sections, from_dt, to_dt) do
    section_summaries =
      Enum.map(scored_sections, fn %{category: cat, items: items} ->
        %{category: cat, count: length(items), preview: preview_text(items)}
      end)

    %DigestRecord{
      user_id: user_id,
      period_start: from_dt,
      period_end: to_dt,
      sections: section_summaries,
      total_items: Enum.sum(Enum.map(section_summaries, & &1.count)),
      generated_at: DateTime.utc_now()
    }
  end

  defp preview_text([first | _]) do
    Map.get(first, :summary, "New activity")
  end

  defp preview_text([]), do: ""
end

defmodule Digests.EmailDigestBuilder.DigestRecord do
  @moduledoc "Structured output of a built digest."

  @enforce_keys [:user_id, :period_start, :period_end, :sections, :total_items, :generated_at]
  defstruct [:user_id, :period_start, :period_end, :sections, :total_items, :generated_at]

  @type section :: %{category: atom(), count: non_neg_integer(), preview: String.t()}
  @type t :: %__MODULE__{
          user_id: String.t(),
          period_start: DateTime.t(),
          period_end: DateTime.t(),
          sections: [section()],
          total_items: non_neg_integer(),
          generated_at: DateTime.t()
        }
end

defmodule Digests.EmailDigestBuilder.ActivityFetcher do
  @moduledoc "Fetches raw activity records for a user within a time window."

  import Ecto.Query

  alias Digests.Repo
  alias Digests.ActivityRecord

  @spec fetch(String.t(), DateTime.t(), DateTime.t()) :: {:ok, [map()]} | {:error, String.t()}
  def fetch(user_id, %DateTime{} = from_dt, %DateTime{} = to_dt)
      when is_binary(user_id) do
    records =
      ActivityRecord
      |> where([a], a.user_id == ^user_id)
      |> where([a], a.occurred_at >= ^from_dt and a.occurred_at <= ^to_dt)
      |> order_by([a], asc: a.occurred_at)
      |> Repo.all()

    {:ok, records}
  rescue
    err -> {:error, "activity fetch failed: #{Exception.message(err)}"}
  end
end
```
