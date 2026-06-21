```elixir
defmodule MyAppWeb.RoomPresence do
  @moduledoc """
  Tracks connected users within collaboration rooms using `Phoenix.Presence`.
  Presence metadata includes the user's display name, avatar URL, and the
  cursor position within a shared document so the UI can render live
  collaborator indicators. The module wraps the raw Presence diff format
  into typed structs for safer consumption by LiveView components.
  """

  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub

  @type presence_meta :: %{
          user_id: binary(),
          display_name: binary(),
          avatar_url: binary() | nil,
          cursor: %{line: non_neg_integer(), column: non_neg_integer()} | nil,
          joined_at: DateTime.t()
        }

  @type presence_entry :: %{
          phx_ref: binary(),
          meta: presence_meta()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Tracks the calling LiveView process as a present user in `room_id`.
  Stores user metadata so all subscribers receive it in presence diffs.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec track_user(binary(), map()) :: :ok | {:error, term()}
  def track_user(room_id, user) when is_binary(room_id) and is_map(user) do
    meta = %{
      user_id: user.id,
      display_name: user.display_name,
      avatar_url: Map.get(user, :avatar_url),
      cursor: nil,
      joined_at: DateTime.utc_now()
    }

    case track(self(), room_id, user.id, meta) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates the cursor position for the current user in `room_id`.
  Only the `:cursor` field is changed; all other metadata is preserved.
  """
  @spec update_cursor(binary(), binary(), %{line: non_neg_integer(), column: non_neg_integer()}) ::
          :ok | {:error, term()}
  def update_cursor(room_id, user_id, cursor)
      when is_binary(room_id) and is_binary(user_id) and is_map(cursor) do
    case get_by_key(room_id, user_id) do
      [] ->
        {:error, :not_tracked}

      [%{metas: [current_meta | _]}] ->
        updated_meta = Map.put(current_meta, :cursor, cursor)

        case update(self(), room_id, user_id, updated_meta) do
          {:ok, _ref} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns a list of `presence_meta()` maps for all users currently in `room_id`,
  deduplicated by `user_id` (keeping the most recent join when the same user
  has multiple tabs open).
  """
  @spec list_users(binary()) :: [presence_meta()]
  def list_users(room_id) when is_binary(room_id) do
    room_id
    |> list()
    |> Map.values()
    |> Enum.map(&most_recent_meta/1)
  end

  @doc """
  Converts a raw Phoenix.Presence diff into a typed `{joins, leaves}` tuple
  containing lists of `presence_meta()`. Intended for use inside
  `handle_info({:presence_diff, ...}, socket)` in a LiveView.
  """
  @spec parse_diff(map()) :: {[presence_meta()], [presence_meta()]}
  def parse_diff(%{joins: joins, leaves: leaves}) do
    parsed_joins = joins |> Map.values() |> Enum.map(&most_recent_meta/1)
    parsed_leaves = leaves |> Map.values() |> Enum.map(&most_recent_meta/1)
    {parsed_joins, parsed_leaves}
  end

  @doc """
  Returns the count of distinct users present in `room_id`.
  """
  @spec user_count(binary()) :: non_neg_integer()
  def user_count(room_id) when is_binary(room_id) do
    room_id |> list() |> map_size()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp most_recent_meta(%{metas: metas}) when is_list(metas) and metas != [] do
    Enum.max_by(metas, & &1.joined_at, DateTime)
  end

  defp most_recent_meta(%{metas: [meta | _]}), do: meta
end
```
