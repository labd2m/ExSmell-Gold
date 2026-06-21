```elixir
defmodule MyApp.Feeds.ActivityFeed do
  @moduledoc """
  Builds paginated activity feeds for users and teams from the
  `activity_events` table. Feed items from multiple event types are
  unified into a consistent `FeedItem` struct so that rendering code
  never needs to branch on raw event shapes.

  All queries use cursor-based pagination keyed on `(occurred_at, id)`
  for stable ordering under concurrent inserts.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Feeds.{ActivityEvent, FeedItem}

  @default_limit 25
  @max_limit 100

  @type feed_cursor :: String.t()

  @type feed_page :: %{
          items: [FeedItem.t()],
          next_cursor: feed_cursor() | nil,
          has_more: boolean()
        }

  @doc """
  Returns a page of activity feed items for `user_id`, optionally
  filtered to a specific `event_type`. Accepts an opaque `cursor` from
  a previous page response.
  """
  @spec for_user(String.t(), keyword()) :: feed_page()
  def for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    cursor = Keyword.get(opts, :cursor)
    event_type = Keyword.get(opts, :event_type)

    ActivityEvent
    |> where([e], e.actor_id == ^user_id or ^user_id in e.audience_ids)
    |> maybe_filter_type(event_type)
    |> apply_cursor(cursor)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^(limit + 1))
    |> Repo.all()
    |> build_page(limit)
  end

  @doc """
  Returns a page of activity feed items visible to all members of `team_id`.
  """
  @spec for_team(String.t(), keyword()) :: feed_page()
  def for_team(team_id, opts \\ []) when is_binary(team_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    cursor = Keyword.get(opts, :cursor)

    ActivityEvent
    |> where([e], e.team_id == ^team_id)
    |> apply_cursor(cursor)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^(limit + 1))
    |> Repo.all()
    |> build_page(limit)
  end

  @spec maybe_filter_type(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [e], e.event_type == ^type)

  @spec apply_cursor(Ecto.Query.t(), feed_cursor() | nil) :: Ecto.Query.t()
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor) do
    case decode_cursor(cursor) do
      {:ok, {ts, id}} ->
        where(query, [e], {e.occurred_at, e.id} < {^ts, ^id})

      :error ->
        query
    end
  end

  @spec build_page([ActivityEvent.t()], pos_integer()) :: feed_page()
  defp build_page(events, limit) do
    has_more = length(events) > limit
    page_events = Enum.take(events, limit)
    items = Enum.map(page_events, &FeedItem.from_event/1)
    next_cursor = if has_more, do: encode_cursor(List.last(page_events)), else: nil
    %{items: items, next_cursor: next_cursor, has_more: has_more}
  end

  @spec encode_cursor(ActivityEvent.t()) :: feed_cursor()
  defp encode_cursor(event) do
    {event.occurred_at, event.id}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  @spec decode_cursor(feed_cursor()) :: {:ok, {DateTime.t(), String.t()}} | :error
  defp decode_cursor(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    _ -> :error
  end
end
```
