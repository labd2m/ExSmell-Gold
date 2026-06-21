```elixir
defmodule Billing.UsageAccumulator do
  @moduledoc """
  Accumulates metered usage events per subscription within the current
  billing period. Counts are stored in ETS for low-latency increments and
  periodically flushed to the database by a supervised GenServer. Callers
  read the live value directly from ETS without going through the process.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias Billing.UsageRecord

  @type subscription_id :: String.t()
  @type metric :: atom()
  @type period_key :: {subscription_id(), metric(), String.t()}

  @table :usage_accumulator
  @flush_interval_ms :timer.seconds(30)

  @doc "Starts the accumulator and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increments `metric` for `subscription_id` in the current period by `amount`."
  @spec increment(subscription_id(), metric(), pos_integer()) :: :ok
  def increment(subscription_id, metric, amount \ 1)
      when is_binary(subscription_id) and is_atom(metric) and is_integer(amount) and amount > 0 do
    key = period_key(subscription_id, metric)
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
    :ok
  end

  @doc "Returns the current accumulated value for the given subscription and metric."
  @spec current(subscription_id(), metric()) :: non_neg_integer()
  def current(subscription_id, metric)
      when is_binary(subscription_id) and is_atom(metric) do
    key = period_key(subscription_id, metric)
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  @doc "Returns all accumulated metrics for `subscription_id` in the current period."
  @spec all_for(subscription_id()) :: %{metric() => non_neg_integer()}
  def all_for(subscription_id) when is_binary(subscription_id) do
    prefix = {subscription_id, :_, current_period()}
    :ets.match_object(@table, prefix)
    |> Map.new(fn {{_sub, metric, _period}, count} -> {metric, count} end)
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    Process.send_after(self(), :flush, interval)
    {:ok, %{flush_interval: interval}}
  end

  @impl GenServer
  def handle_info(:flush, %{flush_interval: interval} = state) do
    flush_to_db()
    Process.send_after(self(), :flush, interval)
    {:noreply, state}
  end

  defp flush_to_db do
    rows = :ets.tab2list(@table)

    if Enum.empty?(rows) do
      :ok
    else
      now = DateTime.utc_now()
      records =
        Enum.map(rows, fn {{sub_id, metric, period}, count} ->
          %{subscription_id: sub_id, metric: Atom.to_string(metric),
            period: period, count: count, updated_at: now}
        end)

      Repo.insert_all(UsageRecord, records,
        on_conflict: {:replace, [:count, :updated_at]},
        conflict_target: [:subscription_id, :metric, :period]
      )

      Logger.debug("[UsageAccumulator] Flushed #{length(records)} usage record(s)")
    end
  rescue
    e -> Logger.error("[UsageAccumulator] Flush failed: #{Exception.message(e)}")
  end

  defp period_key(subscription_id, metric) do
    {subscription_id, metric, current_period()}
  end

  defp current_period do
    today = Date.utc_today()
    "#{today.year}-#{today.month |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
```
