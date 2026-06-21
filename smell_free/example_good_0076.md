```elixir
defmodule Auth.Session do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          claims: map(),
          created_at: integer(),
          expires_at: integer()
        }

  defstruct [:id, :user_id, :claims, :created_at, :expires_at]

  @spec new(String.t(), map(), pos_integer()) :: t()
  def new(user_id, claims, ttl_seconds)
      when is_binary(user_id) and is_map(claims) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    now = System.system_time(:second)

    %__MODULE__{
      id: generate_id(),
      user_id: user_id,
      claims: claims,
      created_at: now,
      expires_at: now + ttl_seconds
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}) do
    System.system_time(:second) >= exp
  end

  defp generate_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end

defmodule Auth.SessionStore do
  @moduledoc """
  Manages short-lived authenticated sessions with automatic expiry.

  Sessions are stored in a public ETS table so reads are lock-free and
  never serialize through this process. Writes and deletes are serialized
  via `GenServer.call/2` to prevent concurrent mutation races. A periodic
  sweeper removes expired sessions to keep memory bounded without requiring
  callers to explicitly clean up.
  """

  use GenServer

  alias Auth.Session

  @table __MODULE__
  @default_ttl 3_600
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create(String.t(), map(), pos_integer()) :: {:ok, Session.t()}
  def create(user_id, claims, ttl_seconds \\ @default_ttl) do
    session = Session.new(user_id, claims, ttl_seconds)
    GenServer.call(__MODULE__, {:put, session})
    {:ok, session}
  end

  @spec fetch(String.t()) :: {:ok, Session.t()} | {:error, :not_found | :expired}
  def fetch(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> validate_expiry(session)
      [] -> {:error, :not_found}
    end
  end

  @spec revoke(String.t()) :: :ok
  def revoke(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:delete, session_id})
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    now = System.system_time(:second)
    :ets.select_count(@table, [{{{:_, %{expires_at: :"$1"}}, [], [{:>, :"$1", now}]}}])
  rescue
    _ -> 0
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, keypos: 1])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, %Session{id: id} = session}, _from, state) do
    :ets.insert(@table, {id, session})
    {:reply, :ok, state}
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    expired_keys = :ets.select(@table, [{{:"$1", %{expires_at: :"$2"}}, [{:<, :"$2", now}], [:"$1"]}])
    Enum.each(expired_keys, &:ets.delete(@table, &1))
    schedule_sweep()
    {:noreply, state}
  end

  defp validate_expiry(session) do
    if Session.expired?(session) do
      {:error, :expired}
    else
      {:ok, session}
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
