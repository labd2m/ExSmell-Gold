```elixir
defmodule Metrics.Aggregator.WindowCounter do
  @moduledoc """
  Maintains a sliding-window event counter per named metric key.
  Counts are stored in a fixed-size circular buffer keyed by second-granularity timestamps.
  """

  use GenServer

  @window_seconds 60

  @type state :: %{
          counts: %{String.t() => %{integer() => non_neg_integer()}},
          window_seconds: pos_integer()
        }

  @doc """
  Starts the WindowCounter linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increments the counter for `metric_key` by `amount`.
  """
  @spec increment(String.t(), pos_integer()) :: :ok
  def increment(metric_key, amount \\ 1)
      when is_binary(metric_key) and is_integer(amount) and amount > 0 do
    GenServer.cast(__MODULE__, {:increment, metric_key, amount})
  end

  @doc """
  Returns the total event count for `metric_key` within the sliding window.
  """
  @spec total(String.t()) :: {:ok, non_neg_integer()}
  def total(metric_key) when is_binary(metric_key) do
    GenServer.call(__MODULE__, {:total, metric_key})
  end

  @doc """
  Returns per-second counts for `metric_key` across the active window.
  """
  @spec breakdown(String.t()) :: {:ok, [{integer(), non_neg_integer()}]}
  def breakdown(metric_key) when is_binary(metric_key) do
    GenServer.call(__MODULE__, {:breakdown, metric_key})
  end

  @impl GenServer
  def init(opts) do
    window = Keyword.get(opts, :window_seconds, @window_seconds)
    {:ok, %{counts: %{}, window_seconds: window}}
  end

  @impl GenServer
  def handle_cast({:increment, metric_key, amount}, state) do
    bucket = current_bucket()
    updated_counts = update_bucket(state.counts, metric_key, bucket, amount)
    {:noreply, %{state | counts: updated_counts}}
  end

  @impl GenServer
  def handle_call({:total, metric_key}, _from, state) do
    cutoff = cutoff_bucket(state.window_seconds)

    total =
      state.counts
      |> Map.get(metric_key, %{})
      |> Enum.filter(fn {ts, _} -> ts >= cutoff end)
      |> Enum.reduce(0, fn {_, count}, acc -> acc + count end)

    {:reply, {:ok, total}, state}
  end

  @impl GenServer
  def handle_call({:breakdown, metric_key}, _from, state) do
    cutoff = cutoff_bucket(state.window_seconds)

    entries =
      state.counts
      |> Map.get(metric_key, %{})
      |> Enum.filter(fn {ts, _} -> ts >= cutoff end)
      |> Enum.sort_by(fn {ts, _} -> ts end)

    {:reply, {:ok, entries}, state}
  end

  defp current_bucket, do: System.system_time(:second)

  defp cutoff_bucket(window), do: System.system_time(:second) - window

  defp update_bucket(counts, metric_key, bucket, amount) do
    metric_buckets = Map.get(counts, metric_key, %{})
    new_count = Map.get(metric_buckets, bucket, 0) + amount
    updated = Map.put(metric_buckets, bucket, new_count)
    Map.put(counts, metric_key, updated)
  end
end
```
