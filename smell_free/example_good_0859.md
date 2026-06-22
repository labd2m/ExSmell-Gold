```elixir
defmodule Social.ActivityFeed do
  @moduledoc """
  A fan-out-on-write activity feed context.

  When a user performs an action (post, comment, follow), an activity record
  is written to the source table and fanned out asynchronously to the timelines
  of all followers. Timelines are paginated using cursor-based reads so they
  remain performant at scale.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Social.{Repo, Activity, TimelineEntry, Follower}

  @type actor_id :: pos_integer()
  @type subject_id :: pos_integer()
  @type verb :: :posted | :commented | :liked | :followed | :shared
  @type activity_result :: {:ok, Activity.t()} | {:error, Ecto.Changeset.t()}
  @type page_opts :: [cursor: String.t() | nil, limit: pos_integer()]

  @doc """
  Records an activity from `actor_id` and fans it out to followers' timelines.
  The fan-out runs asynchronously under a supervised task.
  """
  @spec record(actor_id(), verb(), String.t(), subject_id(), map()) :: activity_result()
  def record(actor_id, verb, object_type, object_id, metadata \\ %{})
      when is_integer(actor_id) and is_atom(verb) do
    attrs = %{
      actor_id: actor_id,
      verb: verb,
      object_type: object_type,
      object_id: object_id,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }

    case %Activity{} |> Activity.changeset(attrs) |> Repo.insert() do
      {:ok, activity} ->
        Task.Supervisor.start_child(Social.TaskSupervisor, fn ->
          fan_out(activity)
        end)
        {:ok, activity}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns a paginated timeline for `user_id`, newest entries first.
  Includes both the user's own activities and those of followed accounts.
  """
  @spec timeline(actor_id(), page_opts()) :: {[Activity.t()], String.t() | nil}
  def timeline(user_id, opts \\ []) when is_integer(user_id) do
    limit = Keyword.get(opts, :limit, 20)
    cursor_id = decode_cursor(Keyword.get(opts, :cursor))

    query =
      from(e in TimelineEntry,
        where: e.recipient_id == ^user_id,
        where: is_nil(^cursor_id) or e.id < ^cursor_id,
        order_by: [desc: e.id],
        limit: ^(limit + 1),
        preload: [:activity]
      )

    entries = Repo.all(query)
    has_more = length(entries) > limit
    page = Enum.take(entries, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(page).id), else: nil

    activities = Enum.map(page, & &1.activity)
    {activities, next_cursor}
  end

  @doc "Returns the count of unread activity entries for `user_id` since `since`."
  @spec unread_count(actor_id(), DateTime.t()) :: non_neg_integer()
  def unread_count(user_id, since) when is_integer(user_id) do
    from(e in TimelineEntry,
      where: e.recipient_id == ^user_id and e.inserted_at > ^since,
      select: count(e.id)
    )
    |> Repo.one()
  end

  defp fan_out(%Activity{actor_id: actor_id} = activity) do
    follower_ids = load_follower_ids(actor_id)

    entries =
      follower_ids
      |> Enum.map(fn follower_id ->
        %{
          recipient_id: follower_id,
          activity_id: activity.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    Repo.insert_all(TimelineEntry, entries, on_conflict: :nothing)
  end

  defp load_follower_ids(actor_id) do
    from(f in Follower,
      where: f.followee_id == ^actor_id,
      select: f.follower_id
    )
    |> Repo.all()
  end

  defp encode_cursor(id), do: Base.url_encode64(Integer.to_string(id), padding: false)

  defp decode_cursor(nil), do: nil
  defp decode_cursor(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, id_str} -> String.to_integer(id_str)
      _ -> nil
    end
  end
end
```
