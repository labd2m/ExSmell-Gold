```elixir
defmodule Ops.SlowQueryDetector do
  @moduledoc """
  Attaches to Ecto's telemetry events and records queries whose duration
  exceeds a configurable threshold. Slow queries are accumulated in a
  bounded buffer and periodically flushed to a structured log and a
  metrics sink so database performance regressions surface automatically
  in the observability stack without requiring manual log mining.
  """

  use GenServer

  require Logger

  @type query_record :: %{
          query: String.t(),
          duration_ms: non_neg_integer(),
          source: String.t() | nil,
          repo: module(),
          recorded_at: DateTime.t()
        }

  @default_threshold_ms 500
  @default_buffer_limit 200
  @flush_interval_ms :timer.minutes(5)
  @handler_id "slow-query-detector"

  @doc "Starts the slow query detector and attaches the telemetry handler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all buffered slow query records, newest first."
  @spec buffered_queries() :: [query_record()]
  def buffered_queries, do: GenServer.call(__MODULE__, :queries)

  @doc "Clears the slow query buffer."
  @spec clear() :: :ok
  def clear, do: GenServer.cast(__MODULE__, :clear)

  @impl GenServer
  def init(opts) do
    threshold_ms = Keyword.get(opts, :threshold_ms, @default_threshold_ms)
    buffer_limit = Keyword.get(opts, :buffer_limit, @default_buffer_limit)

    :telemetry.attach(
      @handler_id,
      [:my_app, :repo, :query],
      &__MODULE__.handle_telemetry_event/4,
      %{threshold_ms: threshold_ms, server: self()}
    )

    Process.send_after(self(), :flush, @flush_interval_ms)
    {:ok, %{queries: [], threshold_ms: threshold_ms, buffer_limit: buffer_limit}}
  end

  @impl GenServer
  def handle_call(:queries, _from, state) do
    {:reply, state.queries, state}
  end

  @impl GenServer
  def handle_cast(:clear, state) do
    {:noreply, %{state | queries: []}}
  end

  @impl GenServer
  def handle_cast({:record, record}, %{queries: queries, buffer_limit: limit} = state) do
    updated = [record | Enum.take(queries, limit - 1)]
    {:noreply, %{state | queries: updated}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    unless Enum.empty?(state.queries) do
      Logger.warning(
        "[SlowQueryDetector] #{length(state.queries)} slow query(ies) recorded in last #{@flush_interval_ms}ms"
      )
    end

    Process.send_after(self(), :flush, @flush_interval_ms)
    {:noreply, state}
  end

  @doc false
  def handle_telemetry_event(
        _event,
        %{total_time: total_time},
        %{query: query, source: source, repo: repo},
        %{threshold_ms: threshold_ms, server: server}
      ) do
    ms = System.convert_time_unit(total_time, :native, :millisecond)

    if ms >= threshold_ms do
      record = %{
        query: query,
        duration_ms: ms,
        source: source,
        repo: repo,
        recorded_at: DateTime.utc_now()
      }

      GenServer.cast(server, {:record, record})
    end
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok
end
```
