# File: `example_good_248.md`

```elixir
defmodule Queue.DeadLetterProcessor do
  @moduledoc """
  GenServer that drains a dead letter queue (DLQ) by attempting
  configurable reprocessing strategies before permanently archiving
  unrecoverable messages.

  Each message tracks its attempt history. The processor applies
  an exponential backoff delay between retries and delegates final
  archival to an injected sink so the storage concern remains
  outside this module.
  """

  use GenServer

  require Logger

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @poll_interval_ms 5_000

  @type message_id :: String.t()

  @type dead_letter :: %{
          required(:id) => message_id(),
          required(:payload) => map(),
          required(:original_queue) => String.t(),
          required(:failure_reason) => String.t(),
          required(:attempt_count) => non_neg_integer(),
          required(:last_attempted_at) => DateTime.t() | nil
        }

  @type opts :: [
          handler: module(),
          archive_sink: module(),
          max_retries: pos_integer(),
          base_delay_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current processing statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    archive_sink = Keyword.fetch!(opts, :archive_sink)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)

    schedule_poll()

    {:ok, %{
      handler: handler,
      archive_sink: archive_sink,
      max_retries: max_retries,
      base_delay_ms: base_delay_ms,
      retried: 0,
      recovered: 0,
      archived: 0
    }}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = Map.take(state, [:retried, :recovered, :archived])
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    messages = state.handler.fetch_dead_letters(50)
    new_state = Enum.reduce(messages, state, &process_message(&2, &1))
    schedule_poll()
    {:noreply, new_state}
  end

  defp process_message(state, %{attempt_count: count} = message) do
    if count >= state.max_retries do
      archive_message(state, message)
    else
      maybe_retry(state, message)
    end
  end

  defp maybe_retry(state, message) do
    delay = backoff_delay(message.attempt_count, state.base_delay_ms)
    last_attempt = message.last_attempted_at

    if should_retry_now?(last_attempt, delay) do
      attempt_retry(state, message)
    else
      state
    end
  end

  defp attempt_retry(state, message) do
    Logger.info("Retrying DLQ message #{message.id} (attempt #{message.attempt_count + 1})")

    case state.handler.reprocess(message) do
      :ok ->
        state.handler.acknowledge(message.id)
        Logger.info("DLQ message #{message.id} recovered successfully")
        %{state | retried: state.retried + 1, recovered: state.recovered + 1}

      {:error, reason} ->
        Logger.warning("DLQ retry failed for #{message.id}: #{inspect(reason)}")
        state.handler.record_attempt(message.id, reason)
        %{state | retried: state.retried + 1}
    end
  end

  defp archive_message(state, message) do
    Logger.warning("Archiving unrecoverable DLQ message #{message.id}")
    state.archive_sink.archive(message)
    state.handler.acknowledge(message.id)
    %{state | archived: state.archived + 1}
  end

  defp should_retry_now?(nil, _delay_ms), do: true

  defp should_retry_now?(last_attempted_at, delay_ms) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_attempted_at, :millisecond)
    elapsed_ms >= delay_ms
  end

  defp backoff_delay(attempt, base_ms) do
    base_ms * Integer.pow(2, attempt)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
```
