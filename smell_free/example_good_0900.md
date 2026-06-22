# File: `example_good_900.md`

```elixir
defmodule Payments.RecurringScheduler do
  @moduledoc """
  GenServer that evaluates a set of recurring payment schedules on each
  tick and triggers charge attempts for schedules whose next payment date
  has arrived.

  Schedules are stored externally; this process reads due schedules,
  attempts charges via an injected adapter, and advances each schedule's
  next_payment_date on success.
  """

  use GenServer

  require Logger

  @default_poll_interval_ms 60_000
  @default_batch_size 100

  @type schedule_id :: String.t()

  @type opts :: [
          store: module(),
          payment_adapter: module(),
          poll_interval_ms: pos_integer(),
          batch_size: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns processing statistics accumulated since the process started.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Triggers an immediate processing tick outside the normal schedule.
  """
  @spec process_now() :: {:ok, map()}
  def process_now do
    GenServer.call(__MODULE__, :process_now, 120_000)
  end

  @impl GenServer
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    payment_adapter = Keyword.fetch!(opts, :payment_adapter)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok, %{
      store: store,
      payment_adapter: payment_adapter,
      poll_interval_ms: poll_interval_ms,
      batch_size: batch_size,
      total_attempted: 0,
      total_succeeded: 0,
      total_failed: 0
    }}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:total_attempted, :total_succeeded, :total_failed]), state}
  end

  @impl GenServer
  def handle_call(:process_now, _from, state) do
    {result, new_state} = run_tick(state)
    {:reply, {:ok, result}, new_state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_result, new_state} = run_tick(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  defp run_tick(state) do
    now = DateTime.utc_now()
    due_schedules = state.store.list_due(now, state.batch_size)

    Logger.info("RecurringScheduler: processing #{length(due_schedules)} due schedule(s)")

    {succeeded, failed} =
      Enum.reduce(due_schedules, {0, 0}, fn schedule, {ok_count, err_count} ->
        case process_schedule(schedule, state.payment_adapter, state.store) do
          :ok -> {ok_count + 1, err_count}
          {:error, _reason} -> {ok_count, err_count + 1}
        end
      end)

    result = %{attempted: length(due_schedules), succeeded: succeeded, failed: failed}

    new_state = %{state |
      total_attempted: state.total_attempted + length(due_schedules),
      total_succeeded: state.total_succeeded + succeeded,
      total_failed: state.total_failed + failed
    }

    {result, new_state}
  end

  defp process_schedule(schedule, payment_adapter, store) do
    case payment_adapter.charge(schedule.customer_id, schedule.amount_cents, schedule.currency) do
      {:ok, _charge} ->
        next_date = advance_date(schedule.next_payment_date, schedule.interval)

        case store.update_next_date(schedule.id, next_date) do
          :ok ->
            Logger.info("Charged schedule #{schedule.id}, next: #{Date.to_iso8601(next_date)}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to advance schedule #{schedule.id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Charge failed for schedule #{schedule.id}: #{inspect(reason)}")
        store.record_failure(schedule.id, reason)
        {:error, reason}
    end
  end

  defp advance_date(date, :monthly), do: Date.add(date, 30)
  defp advance_date(date, :weekly), do: Date.add(date, 7)
  defp advance_date(date, :annual), do: Date.add(date, 365)
  defp advance_date(date, {:days, n}) when is_integer(n), do: Date.add(date, n)

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
