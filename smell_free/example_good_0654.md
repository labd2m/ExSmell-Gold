```elixir
defmodule Metrics.CustomerAggregator do
  @moduledoc """
  Accumulates per-customer event counters in memory and flushes aggregated
  windows to the database on a configurable schedule. Buffering in memory
  reduces write amplification from high-frequency events (API calls, page
  views) by several orders of magnitude. Each window is flushed atomically
  via a single `Repo.insert_all/2` call per customer so the flush is fast
  regardless of event volume within the window.
  """

  use GenServer

  alias Metrics.{AggregateWindow, Repo}

  require Logger

  @type customer_id :: binary()
  @type metric_name :: binary()
  @type window_seconds :: pos_integer()

  @default_window_seconds 60
  @flush_jitter_ms 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increments `metric_name` for `customer_id` by `amount` within the current
  open window. Thread-safe; all writes serialise through the GenServer.
  """
  @spec increment(customer_id(), metric_name(), pos_integer()) :: :ok
  def increment(customer_id, metric_name, amount \\ 1)
      when is_binary(customer_id) and is_binary(metric_name) and is_integer(amount) and amount > 0 do
    GenServer.cast(__MODULE__, {:increment, customer_id, metric_name, amount})
  end

  @doc """
  Returns the current in-memory buffer for `customer_id` without flushing.
  Useful for real-time dashboards that want the freshest possible numbers.
  """
  @spec current_buffer(customer_id()) :: %{metric_name() => non_neg_integer()}
  def current_buffer(customer_id) when is_binary(customer_id) do
    GenServer.call(__MODULE__, {:buffer, customer_id})
  end

  @doc """
  Forces an immediate flush of all buffered data to the database.
  Returns the number of customer windows written.
  """
  @spec flush() :: {:ok, non_neg_integer()}
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)
    schedule_flush(window_seconds)

    state = %{
      buffer: %{},
      window_seconds: window_seconds,
      window_opened_at: System.system_time(:second)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:increment, customer_id, metric, amount}, state) do
    new_buffer =
      Map.update(state.buffer, customer_id, %{metric => amount}, fn customer_metrics ->
        Map.update(customer_metrics, metric, amount, &(&1 + amount))
      end)

    {:noreply, %{state | buffer: new_buffer}}
  end

  @impl GenServer
  def handle_call({:buffer, customer_id}, _from, state) do
    {:reply, Map.get(state.buffer, customer_id, %{}), state}
  end

  def handle_call(:flush, _from, state) do
    {count, new_state} = do_flush(state)
    {:reply, {:ok, count}, new_state}
  end

  @impl GenServer
  def handle_info(:flush_window, state) do
    {_count, new_state} = do_flush(state)
    schedule_flush(state.window_seconds)
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_flush(%{buffer: buffer} = state) when map_size(buffer) == 0 do
    {0, %{state | window_opened_at: System.system_time(:second)}}
  end

  defp do_flush(state) do
    window_start = DateTime.from_unix!(state.window_opened_at)
    window_end = DateTime.utc_now()
    rows = build_rows(state.buffer, window_start, window_end)

    case Repo.insert_all(AggregateWindow, rows, on_conflict: :nothing) do
      {count, _} ->
        Logger.info("Flushed metric windows",
          customer_count: map_size(state.buffer),
          row_count: count,
          window_start: DateTime.to_iso8601(window_start)
        )

        new_state = %{state | buffer: %{}, window_opened_at: System.system_time(:second)}
        {map_size(state.buffer), new_state}
    end
  end

  defp build_rows(buffer, window_start, window_end) do
    now = DateTime.utc_now()

    Enum.flat_map(buffer, fn {customer_id, metrics} ->
      Enum.map(metrics, fn {metric_name, value} ->
        %{
          customer_id: customer_id,
          metric_name: metric_name,
          value: value,
          window_start: window_start,
          window_end: window_end,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
  end

  defp schedule_flush(window_seconds) do
    jitter = :rand.uniform(@flush_jitter_ms)
    delay_ms = window_seconds * 1_000 + jitter
    Process.send_after(self(), :flush_window, delay_ms)
  end
end
```
