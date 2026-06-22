```elixir
defmodule Feeds.ActivityContext do
  @moduledoc """
  Records and retrieves structured activity feed entries for users.
  Entries are immutable once written and are queried with cursor-based
  pagination to support infinite-scroll feed rendering.
  """

  alias Feeds.{Repo, ActivityEntry}
  import Ecto.Query

  @type actor_ref :: %{id: String.t(), type: String.t(), display_name: String.t()}
  @type object_ref :: %{id: String.t(), type: String.t(), display_name: String.t()}
  @type verb :: atom()

  @type activity_params :: %{
          actor: actor_ref(),
          verb: verb(),
          object: object_ref(),
          target_user_ids: [String.t()],
          metadata: map()
        }

  @type page :: %{
          entries: [ActivityEntry.t()],
          next_cursor: String.t() | nil,
          has_more: boolean()
        }

  @page_size 20

  @spec record(activity_params()) :: {:ok, ActivityEntry.t()} | {:error, Ecto.Changeset.t()}
  def record(params) when is_map(params) do
    %ActivityEntry{}
    |> ActivityEntry.creation_changeset(%{
      actor_id: params.actor.id,
      actor_type: params.actor.type,
      actor_display_name: params.actor.display_name,
      verb: to_string(params.verb),
      object_id: params.object.id,
      object_type: params.object.type,
      object_display_name: params.object.display_name,
      target_user_ids: params.target_user_ids,
      metadata: params.metadata,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec feed_for_user(String.t(), keyword()) :: page()
  def feed_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, @page_size)
    cursor = Keyword.get(opts, :cursor)

    query =
      from(a in ActivityEntry,
        where: ^user_id in a.target_user_ids,
        order_by: [desc: a.occurred_at, desc: a.id]
      )

    query
    |> apply_cursor(cursor)
    |> limit(^(limit + 1))
    |> Repo.all()
    |> build_page(limit)
  end

  @spec feed_by_actor(String.t(), keyword()) :: page()
  def feed_by_actor(actor_id, opts \\ []) when is_binary(actor_id) do
    limit = Keyword.get(opts, :limit, @page_size)
    cursor = Keyword.get(opts, :cursor)

    from(a in ActivityEntry,
      where: a.actor_id == ^actor_id,
      order_by: [desc: a.occurred_at, desc: a.id]
    )
    |> apply_cursor(cursor)
    |> limit(^(limit + 1))
    |> Repo.all()
    |> build_page(limit)
  end

  @spec mark_seen(String.t(), [String.t()]) :: {non_neg_integer(), nil}
  def mark_seen(user_id, entry_ids) when is_binary(user_id) and is_list(entry_ids) do
    from(a in ActivityEntry,
      where: a.id in ^entry_ids and ^user_id in a.target_user_ids
    )
    |> Repo.update_all(set: [seen: true])
  end

  @spec apply_cursor(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor) do
    case Base.decode64(cursor) do
      {:ok, decoded} ->
        case String.split(decoded, "|", parts: 2) do
          [ts_str, id] ->
            case DateTime.from_iso8601(ts_str) do
              {:ok, ts, _} ->
                from(a in query,
                  where: a.occurred_at < ^ts or (a.occurred_at == ^ts and a.id < ^id)
                )
              _ -> query
            end
          _ -> query
        end
      _ -> query
    end
  end

  @spec build_page([ActivityEntry.t()], pos_integer()) :: page()
  defp build_page(entries, limit) do
    has_more = length(entries) > limit
    page_entries = Enum.take(entries, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(page_entries)), else: nil
    %{entries: page_entries, next_cursor: next_cursor, has_more: has_more}
  end

  @spec encode_cursor(ActivityEntry.t()) :: String.t()
  defp encode_cursor(entry) do
    "#{DateTime.to_iso8601(entry.occurred_at)}|#{entry.id}" |> Base.encode64()
  end
end
```
