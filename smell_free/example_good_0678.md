```elixir
defmodule Dedup.Window do
  @moduledoc """
  Prevents duplicate event processing within a configurable sliding time window.

  A fingerprint is derived from each event and stored in an ETS table with an
  expiry timestamp. Events whose fingerprint was seen within the window are
  rejected; all others are accepted and their fingerprint recorded. A periodic
  sweeper removes expired entries to bound memory growth.
  """

  use GenServer

  @table __MODULE__

  @type opts :: [window_ms: pos_integer(), sweep_interval_ms: pos_integer()]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_and_record(term()) :: :ok | {:error, :duplicate}
  def check_and_record(event) do
    fp = fingerprint(event)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, fp) do
      [{^fp, expires_at}] when expires_at > now ->
        {:error, :duplicate}

      _ ->
        GenServer.call(__MODULE__, {:record, fp})
    end
  end

  @spec seen?(term()) :: boolean()
  def seen?(event) do
    fp = fingerprint(event)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, fp) do
      [{^fp, expires_at}] when expires_at > now -> true
      _ -> false
    end
  end

  @spec window_size() :: non_neg_integer()
  def window_size, do: :ets.info(@table, :size)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    window_ms = Keyword.get(opts, :window_ms, 60_000)
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, 30_000)
    schedule_sweep(sweep_interval)
    {:ok, %{window_ms: window_ms, sweep_interval_ms: sweep_interval}}
  end

  @impl GenServer
  def handle_call({:record, fp}, _from, state) do
    expires_at = System.monotonic_time(:millisecond) + state.window_ms
    :ets.insert(@table, {fp, expires_at})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    expired = :ets.select(@table, [{{:"$1", :"$2"}, [{:<=, :"$2", now}], [:"$1"]}])
    Enum.each(expired, &:ets.delete(@table, &1))
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp fingerprint(event) do
    :crypto.hash(:sha256, :erlang.term_to_binary(event))
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end

defmodule Dedup.Middleware do
  @moduledoc """
  A composable wrapper that guards any function call with deduplication.
  """

  alias Dedup.Window

  @spec wrap(term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :duplicate | term()}
  def wrap(event_key, fun) when is_function(fun, 0) do
    case Window.check_and_record(event_key) do
      :ok -> fun.()
      {:error, :duplicate} -> {:error, :duplicate}
    end
  end
end
```
