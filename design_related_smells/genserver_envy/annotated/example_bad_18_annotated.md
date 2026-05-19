# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `AuditAggregatorTask` — `Task` acting as a persistent log aggregator
- **Affected function(s):** `start_aggregator/1`, `aggregator_loop/1`
- **Short explanation:** The `Task` maintains an audit log buffer, responds to query and flush messages, batches writes to the database, and enforces buffer limits — a server with client-facing API, which is the purpose of a `GenServer`.

```elixir
defmodule MyApp.AuditAggregatorTask do
  @moduledoc """
  Buffers audit log entries and periodically flushes them in batches
  to the audit database to reduce per-event write pressure.
  """

  alias MyApp.{AuditRepo, MetricsCollector}
  alias MyApp.Audit.{Entry, Batch}

  @flush_interval_ms 10_000
  @max_buffer_size 500
  @batch_size 100

  def start_aggregator(config) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because a Task is used to implement a stateful
    # server that buffers incoming audit entries, handles flush commands, responds
    # to query requests, and manages a periodic timer. It receives messages from
    # many callers and sends back replies — the hallmark of a GenServer, not a
    # one-shot async computation that a Task is intended for.
    Task.start_link(fn ->
      state = %{
        config: config,
        buffer: [],
        flushed_count: 0,
        dropped_count: 0,
        last_flush_at: DateTime.utc_now()
      }

      schedule_flush()
      aggregator_loop(state)
    end)
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp aggregator_loop(state) do
    receive do
      {:log, from, %Entry{} = entry} ->
        if length(state.buffer) >= @max_buffer_size do
          MetricsCollector.increment(:audit_drops)
          send(from, {:error, :buffer_full})
          aggregator_loop(%{state | dropped_count: state.dropped_count + 1})
        else
          enriched = %{entry | aggregator_node: node(), buffered_at: DateTime.utc_now()}
          send(from, :ok)
          aggregator_loop(%{state | buffer: [enriched | state.buffer]})
        end

      :flush ->
        new_state = flush_buffer(state)
        schedule_flush()
        aggregator_loop(new_state)

      {:force_flush, from} ->
        new_state = flush_buffer(state)
        send(from, {:ok, new_state.flushed_count})
        aggregator_loop(new_state)

      {:query, from, filters} ->
        matching =
          Enum.filter(state.buffer, fn entry ->
            Enum.all?(filters, fn {k, v} -> Map.get(entry, k) == v end)
          end)

        send(from, {:ok, matching})
        aggregator_loop(state)

      {:stats, from} ->
        stats = %{
          buffer_size: length(state.buffer),
          flushed_count: state.flushed_count,
          dropped_count: state.dropped_count,
          last_flush_at: state.last_flush_at
        }
        send(from, {:ok, stats})
        aggregator_loop(state)

      :stop ->
        flush_buffer(state)
        :ok
    end
  end

  # VALIDATION: SMELL END

  defp flush_buffer(%{buffer: []} = state), do: %{state | last_flush_at: DateTime.utc_now()}

  defp flush_buffer(state) do
    batches = Enum.chunk_every(state.buffer, @batch_size)

    {ok, errors} =
      batches
      |> Enum.map(fn entries ->
        batch = %Batch{entries: entries, created_at: DateTime.utc_now()}
        AuditRepo.insert_batch(batch)
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    flushed = length(ok) * @batch_size
    MetricsCollector.counter(:audit_flushed, flushed)

    if length(errors) > 0 do
      MetricsCollector.increment(:audit_flush_errors, length(errors))
    end

    %{
      state
      | buffer: [],
        flushed_count: state.flushed_count + flushed,
        last_flush_at: DateTime.utc_now()
    }
  end

  def log(pid, entry) do
    send(pid, {:log, self(), entry})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      2_000 -> {:error, :timeout}
    end
  end

  def force_flush(pid) do
    send(pid, {:force_flush, self()})

    receive do
      {:ok, count} -> {:ok, count}
    after
      30_000 -> {:error, :timeout}
    end
  end

  def query(pid, filters) do
    send(pid, {:query, self(), filters})

    receive do
      {:ok, entries} -> {:ok, entries}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
