# File: `example_good_199.md`

```elixir
defmodule Billing.UsageMeter do
  @moduledoc """
  GenServer that accumulates metered usage events in memory and flushes
  aggregated totals to the billing database on a configurable interval.

  Writing usage increments to this process instead of directly to the
  database reduces write amplification for high-frequency billing events
  such as API calls or storage byte-hours.
  """

  use GenServer

  require Logger

  alias Billing.{Repo, UsageRecord}

  @default_flush_interval_ms 15_000
  @default_max_buffer 10_000

  @type account_id :: String.t()
  @type metric :: atom()
  @type quantity :: number()

  @type opts :: [
          flush_interval_ms: pos_integer(),
          max_buffer: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increments the usage counter for `metric` on `account_id` by `quantity`.

  Returns `:ok` immediately. If the in-memory buffer is full an emergency
  flush is triggered before the increment is recorded.
  """
  @spec increment(account_id(), metric(), quantity()) :: :ok
  def increment(account_id, metric, quantity)
      when is_binary(account_id) and is_atom(metric) and is_number(quantity) and quantity > 0 do
    GenServer.cast(__MODULE__, {:increment, account_id, metric, quantity})
  end

  @doc """
  Forces an immediate flush of the in-memory buffer to the database,
  bypassing the regular interval timer.

  Returns `{:ok, flushed_count}` with the number of distinct account/metric
  combinations written.
  """
  @spec flush() :: {:ok, non_neg_integer()}
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  @doc """
  Returns the current in-memory buffer without flushing it.
  """
  @spec peek() :: %{{account_id(), metric()} => quantity()}
  def peek do
    GenServer.call(__MODULE__, :peek)
  end

  @impl GenServer
  def init(opts) do
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    max_buffer = Keyword.get(opts, :max_buffer, @default_max_buffer)

    schedule_flush(flush_interval_ms)

    {:ok, %{buffer: %{}, flush_interval_ms: flush_interval_ms, max_buffer: max_buffer,
            total_flushed: 0}}
  end

  @impl GenServer
  def handle_cast({:increment, account_id, metric, quantity}, state) do
    new_state =
      if map_size(state.buffer) >= state.max_buffer do
        Logger.warning("UsageMeter buffer full, forcing emergency flush")
        {_count, flushed_state} = do_flush(state)
        flushed_state
      else
        state
      end

    key = {account_id, metric}
    updated_buffer = Map.update(new_state.buffer, key, quantity, &(&1 + quantity))
    {:noreply, %{new_state | buffer: updated_buffer}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {count, new_state} = do_flush(state)
    {:reply, {:ok, count}, new_state}
  end

  @impl GenServer
  def handle_call(:peek, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    {_count, new_state} = do_flush(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, new_state}
  end

  defp do_flush(%{buffer: buffer} = state) when map_size(buffer) == 0 do
    {0, state}
  end

  defp do_flush(%{buffer: buffer} = state) do
    entries = build_entries(buffer)

    case Repo.insert_all(UsageRecord, entries, on_conflict: :replace_all,
                         conflict_target: [:account_id, :metric, :period_start]) do
      {count, _} ->
        {count, %{state | buffer: %{}, total_flushed: state.total_flushed + count}}
    end
  rescue
    error ->
      Logger.error("UsageMeter flush failed: #{Exception.message(error)}")
      {0, state}
  end

  defp build_entries(buffer) do
    period_start = current_period_start()
    now = DateTime.utc_now()

    Enum.map(buffer, fn {{account_id, metric}, quantity} ->
      %{
        account_id: account_id,
        metric: Atom.to_string(metric),
        quantity: quantity,
        period_start: period_start,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp current_period_start do
    now = DateTime.utc_now()
    %{now | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :scheduled_flush, interval_ms)
  end
end
```
