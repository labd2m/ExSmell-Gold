```elixir
defmodule Authx.SessionRegistry do
  @moduledoc """
  Manages active user sessions backed by an Agent for in-memory state.
  All interactions with the underlying Agent are encapsulated within this
  module. External callers use only the typed public API below.
  """

  use Agent

  @type session_id :: String.t()
  @type session :: %{
          user_id: String.t(),
          roles: [String.t()],
          ip_address: String.t(),
          started_at: DateTime.t(),
          expires_at: DateTime.t()
        }
  @type registry :: %{session_id() => session()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec put(session_id(), session()) :: :ok
  def put(session_id, %{user_id: _, roles: _, ip_address: _, started_at: _, expires_at: _} = session)
      when is_binary(session_id) do
    Agent.update(__MODULE__, fn registry ->
      Map.put(registry, session_id, session)
    end)
  end

  @spec fetch(session_id()) :: {:ok, session()} | {:error, :not_found} | {:error, :expired}
  def fetch(session_id) when is_binary(session_id) do
    Agent.get(__MODULE__, fn registry ->
      Map.get(registry, session_id)
    end)
    |> evaluate_session()
  end

  @spec delete(session_id()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    Agent.update(__MODULE__, fn registry ->
      Map.delete(registry, session_id)
    end)
  end

  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    now = DateTime.utc_now()

    Agent.get_and_update(__MODULE__, fn registry ->
      {expired, active} =
        Enum.split_with(registry, fn {_id, session} ->
          DateTime.compare(session.expires_at, now) == :lt
        end)

      {length(expired), Map.new(active)}
    end)
  end

  @spec count() :: non_neg_integer()
  def count do
    Agent.get(__MODULE__, &map_size/1)
  end

  @spec active_for_user(String.t()) :: [session_id()]
  def active_for_user(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    Agent.get(__MODULE__, fn registry ->
      registry
      |> Enum.filter(fn {_id, session} ->
        session.user_id == user_id and
          DateTime.compare(session.expires_at, now) == :gt
      end)
      |> Enum.map(fn {id, _session} -> id end)
    end)
  end

  @spec revoke_all_for_user(String.t()) :: non_neg_integer()
  def revoke_all_for_user(user_id) when is_binary(user_id) do
    Agent.get_and_update(__MODULE__, fn registry ->
      {to_revoke, remaining} =
        Enum.split_with(registry, fn {_id, session} ->
          session.user_id == user_id
        end)

      {length(to_revoke), Map.new(remaining)}
    end)
  end

  @spec evaluate_session(session() | nil) ::
          {:ok, session()} | {:error, :not_found} | {:error, :expired}
  defp evaluate_session(nil), do: {:error, :not_found}

  defp evaluate_session(session) do
    if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
      {:ok, session}
    else
      {:error, :expired}
    end
  end
end

defmodule Authx.SessionRegistry.Sweeper do
  @moduledoc """
  Periodic GenServer that purges expired sessions from the registry
  on a configurable interval to prevent unbounded memory growth.
  """

  use GenServer

  alias Authx.SessionRegistry

  @default_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    count = SessionRegistry.purge_expired()
    :telemetry.execute([:authx, :session, :sweep], %{purged: count}, %{})
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
```
