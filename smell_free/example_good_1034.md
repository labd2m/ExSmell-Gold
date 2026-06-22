```elixir
defmodule Comms.AnnouncementContext do
  @moduledoc """
  Manages platform-wide announcements shown to users in the UI. Announcements
  have a type, a message, and an optional expiry. Active announcements are
  served from an ETS cache that is invalidated on every write. Dismissal
  is tracked per user so each user sees an announcement only until they
  explicitly close it.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Comms.{Announcement, AnnouncementDismissal}

  @type announcement_id :: Ecto.UUID.t()
  @type user_id :: String.t()
  @type announcement_type :: :info | :warning | :critical | :maintenance

  @table :active_announcements

  @doc "Creates a new platform announcement. Invalidates the ETS cache."
  @spec create(announcement_type(), String.t(), DateTime.t() | nil) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()}
  def create(type, message, expires_at \\ nil)
      when type in [:info, :warning, :critical, :maintenance] and is_binary(message) do
    attrs = %{type: Atom.to_string(type), message: message, active: true, expires_at: expires_at}

    case %Announcement{} |> Announcement.changeset(attrs) |> Repo.insert() do
      {:ok, announcement} ->
        invalidate_cache()
        {:ok, announcement}

      {:error, _} = err ->
        err
    end
  end

  @doc "Deactivates an announcement, removing it from the active feed."
  @spec deactivate(announcement_id()) :: :ok | {:error, :not_found}
  def deactivate(announcement_id) when is_binary(announcement_id) do
    case Repo.get(Announcement, announcement_id) do
      nil -> {:error, :not_found}
      ann ->
        ann |> Announcement.changeset(%{active: false}) |> Repo.update!()
        invalidate_cache()
        :ok
    end
  end

  @doc "Returns active announcements not yet dismissed by `user_id`."
  @spec for_user(user_id()) :: [Announcement.t()]
  def for_user(user_id) when is_binary(user_id) do
    dismissed_ids = dismissed_announcement_ids(user_id)
    active_announcements() |> Enum.reject(fn a -> a.id in dismissed_ids end)
  end

  @doc "Records that `user_id` has dismissed `announcement_id`."
  @spec dismiss(announcement_id(), user_id()) :: :ok
  def dismiss(announcement_id, user_id)
      when is_binary(announcement_id) and is_binary(user_id) do
    attrs = %{announcement_id: announcement_id, user_id: user_id}

    %AnnouncementDismissal{}
    |> AnnouncementDismissal.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:announcement_id, :user_id])

    :ok
  end

  @doc "Returns all currently active (non-expired) announcements."
  @spec active_announcements() :: [Announcement.t()]
  def active_announcements do
    case :ets.info(@table) do
      :undefined ->
        load_active()

      _ ->
        case :ets.lookup(@table, :all) do
          [{:all, announcements}] -> announcements
          [] -> load_and_cache()
        end
    end
  end

  defp load_active do
    now = DateTime.utc_now()

    from(a in Announcement,
      where: a.active == true and (is_nil(a.expires_at) or a.expires_at > ^now),
      order_by: [desc: a.inserted_at]
    )
    |> Repo.all()
  end

  defp load_and_cache do
    announcements = load_active()

    ensure_table()
    :ets.insert(@table, {:all, announcements})
    announcements
  end

  defp invalidate_cache do
    if :ets.info(@table) != :undefined do
      :ets.delete(@table, :all)
    end

    load_and_cache()
    :ok
  end

  defp dismissed_announcement_ids(user_id) do
    from(d in AnnouncementDismissal,
      where: d.user_id == ^user_id,
      select: d.announcement_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end
end
```
