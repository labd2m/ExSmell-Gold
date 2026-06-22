```elixir
defmodule Presence.Counter do
  @moduledoc """
  Tracks the number of live connections per resource across all cluster nodes
  using Erlang's `:pg` process groups. Each connection registers a lightweight
  monitor process in the appropriate group; when the client disconnects, the
  monitor process exits and the count decrements automatically via process
  death. This approach requires no GenServer serialisation for reads — the
  count is derived directly from `:pg.get_members/2` and is consistent
  across the cluster without any synchronisation overhead.
  """

  @scope __MODULE__

  @doc """
  Initialises the `:pg` scope. Call once from `Application.start/2`.
  """
  @spec start_link() :: {:ok, pid()}
  def start_link do
    :pg.start_link(@scope)
  end

  @doc """
  Registers the calling process as a presence for `resource_id`.
  The presence is automatically removed when the calling process exits.
  Returns `{:ok, count}` where `count` is the new total including this join.
  """
  @spec join(binary()) :: {:ok, non_neg_integer()}
  def join(resource_id) when is_binary(resource_id) do
    group = group_name(resource_id)
    :ok = :pg.join(@scope, group, self())
    count = :pg.get_members(@scope, group) |> length()
    {:ok, count}
  end

  @doc """
  Removes the calling process from the presence group for `resource_id`.
  Returns `{:ok, remaining}` with the count after leaving.
  """
  @spec leave(binary()) :: {:ok, non_neg_integer()}
  def leave(resource_id) when is_binary(resource_id) do
    group = group_name(resource_id)
    :ok = :pg.leave(@scope, group, self())
    count = :pg.get_members(@scope, group) |> length()
    {:ok, count}
  end

  @doc """
  Returns the current presence count for `resource_id` across the cluster.
  """
  @spec count(binary()) :: non_neg_integer()
  def count(resource_id) when is_binary(resource_id) do
    group = group_name(resource_id)

    case :pg.get_members(@scope, group) do
      pids when is_list(pids) -> length(pids)
      _ -> 0
    end
  end

  @doc """
  Returns `true` when at least one process is present for `resource_id`.
  """
  @spec any?(binary()) :: boolean()
  def any?(resource_id) when is_binary(resource_id) do
    count(resource_id) > 0
  end

  @doc """
  Returns a list of `{resource_id, count}` pairs for all groups with at
  least one member. Useful for populating active-room dashboards.
  """
  @spec all_active() :: [{binary(), non_neg_integer()}]
  def all_active do
    :pg.which_groups(@scope)
    |> Enum.map(fn group ->
      resource_id = resource_id_from_group(group)
      count = :pg.get_members(@scope, group) |> length()
      {resource_id, count}
    end)
    |> Enum.filter(fn {_id, count} -> count > 0 end)
  end

  @doc """
  Spawns a dedicated presence monitor process linked to `owner_pid`.
  When the owner exits the monitor exits too, automatically leaving the group.
  Use this when the registering process must not block on join/leave calls.
  """
  @spec monitor(binary(), pid()) :: {:ok, pid()}
  def monitor(resource_id, owner_pid \\ self()) when is_binary(resource_id) do
    {:ok, pid} =
      Task.start(fn ->
        Process.flag(:trap_exit, true)
        Process.link(owner_pid)
        join(resource_id)

        receive do
          {:EXIT, ^owner_pid, _reason} -> leave(resource_id)
        end
      end)

    {:ok, pid}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp group_name(resource_id), do: :"presence:#{resource_id}"

  defp resource_id_from_group(group) do
    group |> Atom.to_string() |> String.replace_prefix("presence:", "")
  end
end
```
