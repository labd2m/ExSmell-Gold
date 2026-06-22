```elixir
defmodule Sessions.SessionStore do
  @moduledoc """
  Manages authenticated user sessions with creation, renewal, and
  invalidation. Sessions are persisted in the database and cached in
  ETS for low-latency read access with a configurable TTL.
  """

  use GenServer

  alias Sessions.{Repo, Session}
  import Ecto.Query

  @cache_table :session_cache
  @default_ttl_seconds 3_600
  @sweep_interval_ms 120_000

  @type session_id :: String.t()
  @type user_id :: String.t()

  @type session_data :: %{
          id: session_id(),
          user_id: user_id(),
          metadata: map(),
          expires_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create(user_id(), map()) :: {:ok, session_data()} | {:error, Ecto.Changeset.t()}
  def create(user_id, metadata \\ %{}) when is_binary(user_id) do
    ttl = Application.get_env(:sessions, :ttl_seconds, @default_ttl_seconds)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

    params = %{user_id: user_id, metadata: metadata, expires_at: expires_at}

    case %Session{} |> Session.creation_changeset(params) |> Repo.insert() do
      {:ok, session} ->
        warm_cache(session)
        {:ok, to_data(session)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec fetch(session_id()) :: {:ok, session_data()} | {:error, :not_found | :expired}
  def fetch(session_id) when is_binary(session_id) do
    case :ets.lookup(@cache_table, session_id) do
      [{^session_id, session}] -> check_session_expiry(session)
      [] -> fetch_from_db(session_id)
    end
  end

  @spec renew(session_id()) :: {:ok, session_data()} | {:error, :not_found | :expired}
  def renew(session_id) when is_binary(session_id) do
    ttl = Application.get_env(:sessions, :ttl_seconds, @default_ttl_seconds)
    new_expiry = DateTime.add(DateTime.utc_now(), ttl, :second)

    with {:ok, _current} <- fetch(session_id),
         {:ok, updated} <- update_expiry(session_id, new_expiry) do
      warm_cache(updated)
      {:ok, to_data(updated)}
    end
  end

  @spec invalidate(session_id()) :: :ok
  def invalidate(session_id) when is_binary(session_id) do
    :ets.delete(@cache_table, session_id)
    from(s in Session, where: s.id == ^session_id) |> Repo.delete_all()
    :ok
  end

  @spec invalidate_all_for_user(user_id()) :: {:ok, non_neg_integer()}
  def invalidate_all_for_user(user_id) when is_binary(user_id) do
    {count, _} =
      from(s in Session, where: s.user_id == ^user_id) |> Repo.delete_all()

    purge_user_cache(user_id)
    {:ok, count}
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    evict_expired()
    schedule_sweep()
    {:noreply, state}
  end

  @spec fetch_from_db(session_id()) :: {:ok, session_data()} | {:error, :not_found | :expired}
  defp fetch_from_db(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> check_session_expiry(session)
    end
  end

  @spec check_session_expiry(Session.t() | session_data()) ::
          {:ok, session_data()} | {:error, :expired}
  defp check_session_expiry(%{expires_at: expires_at} = session) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      data = if is_struct(session, Session), do: to_data(session), else: session
      {:ok, data}
    else
      {:error, :expired}
    end
  end

  @spec update_expiry(session_id(), DateTime.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  defp update_expiry(session_id, new_expiry) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> session |> Session.renewal_changeset(%{expires_at: new_expiry}) |> Repo.update()
    end
  end

  @spec warm_cache(Session.t()) :: true
  defp warm_cache(session), do: :ets.insert(@cache_table, {session.id, to_data(session)})

  @spec purge_user_cache(user_id()) :: :ok
  defp purge_user_cache(user_id) do
    @cache_table
    |> :ets.tab2list()
    |> Enum.each(fn {id, data} ->
      if data.user_id == user_id, do: :ets.delete(@cache_table, id)
    end)
  end

  @spec evict_expired() :: :ok
  defp evict_expired do
    now = DateTime.utc_now()

    @cache_table
    |> :ets.tab2list()
    |> Enum.each(fn {id, data} ->
      if DateTime.compare(data.expires_at, now) != :gt, do: :ets.delete(@cache_table, id)
    end)
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @spec to_data(Session.t()) :: session_data()
  defp to_data(session) do
    %{
      id: session.id,
      user_id: session.user_id,
      metadata: session.metadata,
      expires_at: session.expires_at
    }
  end
end
```
