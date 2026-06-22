**File:** `example_good_1302.md`

```elixir
defmodule Sessions.Session do
  @moduledoc "Immutable value object representing a user session's state."

  @enforce_keys [:id, :user_id, :created_at, :last_active_at, :expires_at]
  defstruct [
    :id,
    :user_id,
    :created_at,
    :last_active_at,
    :expires_at,
    ip_address: nil,
    user_agent: nil,
    data: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          created_at: DateTime.t(),
          last_active_at: DateTime.t(),
          expires_at: DateTime.t(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          data: map()
        }

  @session_ttl_seconds 86_400

  @spec create(String.t(), keyword()) :: t()
  def create(user_id, opts \\ []) when is_binary(user_id) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      user_id: user_id,
      created_at: now,
      last_active_at: now,
      expires_at: DateTime.add(now, @session_ttl_seconds, :second),
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent),
      data: Keyword.get(opts, :data, %{})
    }
  end

  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = session) do
    now = DateTime.utc_now()
    %{session | last_active_at: now, expires_at: DateTime.add(now, @session_ttl_seconds, :second)}
  end

  @spec put_data(t(), atom(), term()) :: t()
  def put_data(%__MODULE__{data: data} = session, key, value) when is_atom(key) do
    %{session | data: Map.put(data, key, value)}
  end

  @spec get_data(t(), atom()) :: term() | nil
  def get_data(%__MODULE__{data: data}, key) when is_atom(key) do
    Map.get(data, key)
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) == :gt
  end

  defp generate_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end

defmodule Sessions.Store do
  @moduledoc """
  A GenServer-backed session store that manages active sessions in memory
  with periodic expiry sweeps to reclaim stale entries.
  """

  use GenServer

  alias Sessions.Session

  @sweep_interval_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec put(Session.t()) :: :ok
  def put(%Session{} = session), do: GenServer.call(__MODULE__, {:put, session})

  @spec get(String.t()) :: {:ok, Session.t()} | {:error, :not_found} | {:error, :expired}
  def get(session_id) when is_binary(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @spec delete(String.t()) :: :ok
  def delete(session_id) when is_binary(session_id), do: GenServer.call(__MODULE__, {:delete, session_id})

  @spec touch(String.t()) :: {:ok, Session.t()} | {:error, :not_found} | {:error, :expired}
  def touch(session_id) when is_binary(session_id), do: GenServer.call(__MODULE__, {:touch, session_id})

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, session}, _from, sessions) do
    {:reply, :ok, Map.put(sessions, session.id, session)}
  end

  def handle_call({:get, id}, _from, sessions) do
    reply = resolve_session(Map.get(sessions, id))
    {:reply, reply, sessions}
  end

  def handle_call({:delete, id}, _from, sessions) do
    {:reply, :ok, Map.delete(sessions, id)}
  end

  def handle_call({:touch, id}, _from, sessions) do
    case Map.get(sessions, id) do
      nil ->
        {:reply, {:error, :not_found}, sessions}

      session ->
        if Session.expired?(session) do
          {:reply, {:error, :expired}, Map.delete(sessions, id)}
        else
          updated = Session.touch(session)
          {:reply, {:ok, updated}, Map.put(sessions, id, updated)}
        end
    end
  end

  @impl GenServer
  def handle_info(:sweep, sessions) do
    active = Map.reject(sessions, fn {_id, session} -> Session.expired?(session) end)
    schedule_sweep()
    {:noreply, active}
  end

  defp resolve_session(nil), do: {:error, :not_found}
  defp resolve_session(session) do
    if Session.expired?(session), do: {:error, :expired}, else: {:ok, session}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
