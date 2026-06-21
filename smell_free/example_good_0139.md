```elixir
defmodule MyApp.Analytics.SessionAggregator do
  @moduledoc """
  A GenServer that maintains in-memory session counts and page-view tallies
  for the last rolling 24 hours, partitioned into 15-minute buckets.
  Expired buckets are dropped automatically when a new event arrives or
  during the periodic sweep, keeping memory usage bounded regardless of
  traffic volume.

  Start this module under the application supervisor:

      children = [MyApp.Analytics.SessionAggregator]
  """

  use GenServer

  require Logger

  @bucket_minutes 15
  @bucket_ms @bucket_minutes * 60 * 1_000
  @retention_ms 24 * 60 * 60 * 1_000
  @sweep_interval_ms 5 * 60 * 1_000

  @type bucket_key :: integer()
  @type bucket :: %{sessions: MapSet.t(), page_views: non_neg_integer()}
  @type state :: %{buckets: %{bucket_key() => bucket()}}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records a page view for `session_id` at the current wall-clock time."
  @spec record_page_view(String.t()) :: :ok
  def record_page_view(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:page_view, session_id, now_ms()})
  end

  @doc """
  Returns aggregate counts for the past `hours` hours (max 24).
  The map contains `:unique_sessions` and `:page_views` totals.
  """
  @spec summary(pos_integer()) :: %{unique_sessions: non_neg_integer(), page_views: non_neg_integer()}
  def summary(hours \\ 24) when is_integer(hours) and hours in 1..24 do
    GenServer.call(__MODULE__, {:summary, hours})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{buckets: %{}}}
  end

  @impl GenServer
  def handle_cast({:page_view, session_id, ts}, state) do
    key = bucket_key(ts)
    bucket = Map.get(state.buckets, key, empty_bucket())

    updated_bucket = %{
      bucket
      | sessions: MapSet.put(bucket.sessions, session_id),
        page_views: bucket.page_views + 1
    }

    new_buckets =
      state.buckets
      |> Map.put(key, updated_bucket)
      |> drop_expired(ts)

    {:noreply, %{state | buckets: new_buckets}}
  end

  @impl GenServer
  def handle_call({:summary, hours}, _from, state) do
    cutoff = now_ms() - hours * 60 * 60 * 1_000

    result =
      state.buckets
      |> Enum.filter(fn {key, _} -> key >= bucket_key(cutoff) end)
      |> Enum.reduce(%{sessions: MapSet.new(), page_views: 0}, fn {_, b}, acc ->
        %{
          sessions: MapSet.union(acc.sessions, b.sessions),
          page_views: acc.page_views + b.page_views
        }
      end)

    {:reply, %{unique_sessions: MapSet.size(result.sessions), page_views: result.page_views},
     state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    new_buckets = drop_expired(state.buckets, now_ms())
    schedule_sweep()
    {:noreply, %{state | buckets: new_buckets}}
  end

  @spec bucket_key(integer()) :: bucket_key()
  defp bucket_key(ts_ms), do: div(ts_ms, @bucket_ms)

  @spec empty_bucket() :: bucket()
  defp empty_bucket, do: %{sessions: MapSet.new(), page_views: 0}

  @spec drop_expired(%{bucket_key() => bucket()}, integer()) :: %{bucket_key() => bucket()}
  defp drop_expired(buckets, now_ms) do
    cutoff_key = bucket_key(now_ms - @retention_ms)
    Map.reject(buckets, fn {key, _} -> key < cutoff_key end)
  end

  @spec now_ms() :: integer()
  defp now_ms, do: System.os_time(:millisecond)

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
