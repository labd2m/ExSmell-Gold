```elixir
defmodule Auth.TokenRegistry do
  @moduledoc """
  A supervised GenServer that tracks active API tokens in an ETS-backed
  registry. Supports token creation, validation, and expiry-based eviction.
  """

  use GenServer

  @table_name :auth_token_registry
  @sweep_interval_ms 60_000

  @type token_entry :: %{
          jti: String.t(),
          user_id: String.t(),
          expires_at: DateTime.t(),
          scopes: [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(token_entry()) :: :ok
  def register(entry) do
    GenServer.call(__MODULE__, {:register, entry})
  end

  @spec validate(String.t()) :: {:ok, token_entry()} | {:error, :not_found | :expired}
  def validate(jti) when is_binary(jti) do
    case :ets.lookup(@table_name, jti) do
      [{^jti, entry}] -> check_expiry(entry)
      [] -> {:error, :not_found}
    end
  end

  @spec revoke(String.t()) :: :ok
  def revoke(jti) when is_binary(jti) do
    GenServer.cast(__MODULE__, {:revoke, jti})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:register, entry}, _from, state) do
    :ets.insert(@table_name, {entry.jti, entry})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:revoke, jti}, state) do
    :ets.delete(@table_name, jti)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep_expired, state) do
    evict_expired_entries()
    schedule_sweep()
    {:noreply, state}
  end

  @spec check_expiry(token_entry()) :: {:ok, token_entry()} | {:error, :expired}
  defp check_expiry(entry) do
    if DateTime.compare(entry.expires_at, DateTime.utc_now()) == :gt do
      {:ok, entry}
    else
      {:error, :expired}
    end
  end

  @spec evict_expired_entries() :: non_neg_integer()
  defp evict_expired_entries do
    now = DateTime.utc_now()

    stale_keys =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_jti, entry} -> DateTime.compare(entry.expires_at, now) != :gt end)
      |> Enum.map(fn {jti, _} -> jti end)

    Enum.each(stale_keys, &:ets.delete(@table_name, &1))
    length(stale_keys)
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end
end
```
