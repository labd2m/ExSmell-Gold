```elixir
defmodule Web.SessionStore do
  @moduledoc """
  In-process session store for short-lived web sessions with automatic TTL expiry.

  Sessions are keyed by opaque string tokens. Background cleanup runs on a
  fixed interval to evict expired sessions without blocking active reads or writes.
  """

  use GenServer

  alias Web.SessionStore.{SessionEntry, Config}

  @default_ttl_seconds 3_600
  @cleanup_interval_ms 60_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Stores a session under the given token, overwriting any existing entry.
  """
  @spec put(String.t(), map(), keyword()) :: :ok
  def put(token, data, opts \\ []) when is_binary(token) and is_map(data) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    GenServer.cast(__MODULE__, {:put, token, data, ttl})
  end

  @doc """
  Retrieves a valid, non-expired session.

  Returns `{:ok, data}` or `{:error, :not_found}` if missing or expired.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:get, token})
  end

  @doc """
  Extends a session's TTL from the current time.
  """
  @spec refresh(String.t(), keyword()) :: :ok | {:error, :not_found}
  def refresh(token, opts \\ []) when is_binary(token) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    GenServer.call(__MODULE__, {:refresh, token, ttl})
  end

  @doc """
  Immediately removes a session by token.
  """
  @spec delete(String.t()) :: :ok
  def delete(token) when is_binary(token) do
    GenServer.cast(__MODULE__, {:delete, token})
  end

  @doc """
  Returns the number of currently active (non-expired) sessions.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    GenServer.call(__MODULE__, :active_count)
  end

  @impl GenServer
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{sessions: %{}}}
  end

  @impl GenServer
  def handle_cast({:put, token, data, ttl}, %{sessions: sessions} = state) do
    entry = SessionEntry.new(data, ttl)
    {:noreply, %{state | sessions: Map.put(sessions, token, entry)}}
  end

  def handle_cast({:delete, token}, %{sessions: sessions} = state) do
    {:noreply, %{state | sessions: Map.delete(sessions, token)}}
  end

  @impl GenServer
  def handle_call({:get, token}, _from, %{sessions: sessions} = state) do
    reply =
      case Map.fetch(sessions, token) do
        {:ok, entry} -> SessionEntry.read(entry)
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:refresh, token}, _from, %{sessions: sessions} = state) do
    case Map.fetch(sessions, token) do
      {:ok, entry} ->
        ttl = entry.ttl_seconds
        refreshed = SessionEntry.new(entry.data, ttl)
        {:reply, :ok, %{state | sessions: Map.put(sessions, token, refreshed)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:active_count, _from, %{sessions: sessions} = state) do
    now = System.system_time(:second)
    count = Enum.count(sessions, fn {_k, entry} -> entry.expires_at > now end)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:cleanup, %{sessions: sessions} = state) do
    now = System.system_time(:second)
    pruned = Map.filter(sessions, fn {_k, entry} -> entry.expires_at > now end)
    schedule_cleanup()
    {:noreply, %{state | sessions: pruned}}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end

defmodule Web.SessionStore.SessionEntry do
  @moduledoc false

  @enforce_keys [:data, :expires_at, :ttl_seconds]
  defstruct [:data, :expires_at, :ttl_seconds]

  @type t :: %__MODULE__{
          data: map(),
          expires_at: integer(),
          ttl_seconds: pos_integer()
        }

  @spec new(map(), pos_integer()) :: t()
  def new(data, ttl_seconds) when is_map(data) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    %__MODULE__{
      data: data,
      ttl_seconds: ttl_seconds,
      expires_at: System.system_time(:second) + ttl_seconds
    }
  end

  @spec read(t()) :: {:ok, map()} | {:error, :not_found}
  def read(%__MODULE__{expires_at: exp, data: data}) do
    if System.system_time(:second) < exp, do: {:ok, data}, else: {:error, :not_found}
  end
end
```
