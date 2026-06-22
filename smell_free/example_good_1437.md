```elixir
defmodule Queue.DeadLetterProcessor do
  @moduledoc """
  Periodically inspects a dead-letter queue, classifies failed messages by
  error category, and either requeues recoverable messages with backoff or
  archives permanently failed ones for manual inspection.
  """

  use GenServer

  alias Queue.{Repo, DeadLetter, BrokerClient, ArchiveStore}
  import Ecto.Query

  @scan_interval_ms 30_000
  @max_retry_attempts 3
  @batch_size 50

  @type classification :: :retryable | :permanent_failure | :expired

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec process_now() :: {:ok, map()}
  def process_now do
    GenServer.call(__MODULE__, :process, 60_000)
  end

  @impl GenServer
  def init(_opts) do
    schedule_scan()
    {:ok, %{processed: 0, requeued: 0, archived: 0}}
  end

  @impl GenServer
  def handle_call(:process, _from, state) do
    result = run_processing_cycle()
    updated = merge_stats(state, result)
    {:reply, {:ok, result}, updated}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    result = run_processing_cycle()
    schedule_scan()
    {:noreply, merge_stats(state, result)}
  end

  @spec run_processing_cycle() :: %{processed: non_neg_integer(), requeued: non_neg_integer(), archived: non_neg_integer()}
  defp run_processing_cycle do
    messages = fetch_batch()

    Enum.reduce(messages, %{processed: 0, requeued: 0, archived: 0}, fn msg, acc ->
      case classify(msg) do
        :retryable -> handle_requeue(msg, acc)
        :permanent_failure -> handle_archive(msg, acc)
        :expired -> handle_archive(msg, acc)
      end
    end)
  end

  @spec classify(DeadLetter.t()) :: classification()
  defp classify(%{attempt_count: attempts, error_type: error_type, inserted_at: inserted_at}) do
    cond do
      attempts >= @max_retry_attempts -> :permanent_failure
      message_expired?(inserted_at) -> :expired
      transient_error?(error_type) -> :retryable
      true -> :permanent_failure
    end
  end

  @spec handle_requeue(DeadLetter.t(), map()) :: map()
  defp handle_requeue(msg, acc) do
    delay_ms = backoff_delay(msg.attempt_count)

    case BrokerClient.requeue(msg.topic, msg.payload, delay_ms: delay_ms) do
      :ok ->
        Repo.delete(msg)
        Map.merge(acc, %{processed: acc.processed + 1, requeued: acc.requeued + 1})

      {:error, _} ->
        Map.update!(acc, :processed, &(&1 + 1))
    end
  end

  @spec handle_archive(DeadLetter.t(), map()) :: map()
  defp handle_archive(msg, acc) do
    ArchiveStore.store(msg)
    Repo.delete(msg)
    Map.merge(acc, %{processed: acc.processed + 1, archived: acc.archived + 1})
  end

  @spec fetch_batch() :: [DeadLetter.t()]
  defp fetch_batch do
    from(d in DeadLetter,
      order_by: [asc: d.inserted_at],
      limit: @batch_size
    )
    |> Repo.all()
  end

  @spec transient_error?(String.t()) :: boolean()
  defp transient_error?(error_type) do
    transient = ["timeout", "connection_refused", "service_unavailable", "rate_limited"]
    error_type in transient
  end

  @spec message_expired?(DateTime.t()) :: boolean()
  defp message_expired?(inserted_at) do
    age_hours = DateTime.diff(DateTime.utc_now(), inserted_at, :hour)
    age_hours >= 72
  end

  @spec backoff_delay(non_neg_integer()) :: pos_integer()
  defp backoff_delay(attempts) do
    round(1_000 * :math.pow(2, attempts))
  end

  @spec merge_stats(map(), map()) :: map()
  defp merge_stats(state, result) do
    %{
      state
      | processed: state.processed + result.processed,
        requeued: state.requeued + result.requeued,
        archived: state.archived + result.archived
    }
  end

  @spec schedule_scan() :: reference()
  defp schedule_scan, do: Process.send_after(self(), :scan, @scan_interval_ms)
end
```
