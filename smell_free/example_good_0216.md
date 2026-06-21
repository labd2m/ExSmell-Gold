```elixir
defmodule MyApp.Realtime.PresenceTracker do
  @moduledoc """
  Tracks which users are currently viewing a shared resource (document,
  board, session) using `Phoenix.Presence`. Provides a clean API for
  joining, leaving, and listing presence without exposing PubSub topic
  strings to callers.

  Intended to be called from LiveView mount/unmount hooks and channel
  join/leave callbacks.
  """

  alias Phoenix.Presence

  @presence MyApp.Presence
  @topic_prefix "presence:"

  @type resource_id :: String.t()
  @type user_meta :: %{
          required(:name) => String.t(),
          required(:avatar_url) => String.t() | nil,
          optional(:cursor_color) => String.t()
        }

  @doc """
  Registers the calling process as an active viewer of `resource_id`.
  Metadata is broadcast to all other subscribers on the topic.
  """
  @spec track(resource_id(), String.t(), user_meta()) :: {:ok, binary()} | {:error, term()}
  def track(resource_id, user_id, meta)
      when is_binary(resource_id) and is_binary(user_id) and is_map(meta) do
    Presence.track(
      self(),
      topic(resource_id),
      user_id,
      Map.put(meta, :joined_at, DateTime.utc_now() |> DateTime.to_unix())
    )
  end

  @doc """
  Removes the calling process from the presence list for `resource_id`.
  """
  @spec untrack(resource_id(), String.t()) :: :ok
  def untrack(resource_id, user_id)
      when is_binary(resource_id) and is_binary(user_id) do
    Presence.untrack(self(), topic(resource_id), user_id)
  end

  @doc """
  Returns the list of users currently present for `resource_id`,
  each annotated with their most recent metadata.
  """
  @spec list(resource_id()) :: [map()]
  def list(resource_id) when is_binary(resource_id) do
    resource_id
    |> topic()
    |> Presence.list()
    |> Enum.map(&format_presence/1)
  end

  @doc "Returns the count of unique users currently viewing `resource_id`."
  @spec count(resource_id()) :: non_neg_integer()
  def count(resource_id) when is_binary(resource_id) do
    resource_id |> topic() |> Presence.list() |> map_size()
  end

  @doc """
  Subscribes the calling process to presence diff events for `resource_id`.
  Messages arrive as `%Phoenix.Socket.Broadcast{event: \"presence_diff\", ...}`.
  """
  @spec subscribe(resource_id()) :: :ok | {:error, term()}
  def subscribe(resource_id) when is_binary(resource_id) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic(resource_id))
  end

  @doc "Unsubscribes the calling process from presence diffs for `resource_id`."
  @spec unsubscribe(resource_id()) :: :ok
  def unsubscribe(resource_id) when is_binary(resource_id) do
    Phoenix.PubSub.unsubscribe(MyApp.PubSub, topic(resource_id))
  end

  @doc """
  Updates the metadata for `user_id` within `resource_id`.
  Useful for broadcasting cursor position or activity status changes.
  """
  @spec update_meta(resource_id(), String.t(), user_meta()) ::
          {:ok, binary()} | {:error, term()}
  def update_meta(resource_id, user_id, meta)
      when is_binary(resource_id) and is_binary(user_id) and is_map(meta) do
    Presence.update(self(), topic(resource_id), user_id, fn existing ->
      Map.merge(existing, meta)
    end)
  end

  @spec topic(resource_id()) :: String.t()
  defp topic(resource_id), do: @topic_prefix <> resource_id

  @spec format_presence({String.t(), map()}) :: map()
  defp format_presence({user_id, %{metas: [meta | _]}}) do
    Map.merge(meta, %{user_id: user_id})
  end
end
```
