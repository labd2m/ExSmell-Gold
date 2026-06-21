# File: `example_good_250.md`

```elixir
defmodule Notifications.BatchSender do
  @moduledoc """
  GenServer that accumulates outbound notifications and dispatches them
  in batches to reduce per-message overhead when sending to external
  delivery providers that support bulk submission.

  Batches are flushed either when they reach the configured size or
  when the flush interval elapses, whichever comes first.
  """

  use GenServer

  require Logger

  @default_batch_size 100
  @default_flush_interval_ms 2_000

  @type notification :: %{
          required(:recipient_id) => String.t(),
          required(:channel) => :email | :sms | :push,
          required(:content) => map()
        }

  @type opts :: [
          adapter: module(),
          batch_size: pos_integer(),
          flush_interval_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a notification for batched dispatch.

  Returns `:ok` immediately. Delivery is not guaranteed until the
  batch containing this notification has been successfully flushed.
  """
  @spec enqueue(notification()) :: :ok
  def enqueue(%{recipient_id: _, channel: _, content: _} = notification) do
    GenServer.cast(__MODULE__, {:enqueue, notification})
  end

  @doc """
  Forces an immediate flush of all pending notifications.

  Returns `{:ok, %{sent: integer, failed: integer}}`.
  """
  @spec flush_now() :: {:ok, map()}
  def flush_now do
    GenServer.call(__MODULE__, :flush_now, 30_000)
  end

  @doc """
  Returns accumulated delivery statistics for this process lifetime.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)

    schedule_flush(flush_interval_ms)

    {:ok, %{
      adapter: adapter,
      batch_size: batch_size,
      flush_interval_ms: flush_interval_ms,
      pending: [],
      total_sent: 0,
      total_failed: 0
    }}
  end

  @impl GenServer
  def handle_cast({:enqueue, notification}, state) do
    new_pending = [notification | state.pending]

    if length(new_pending) >= state.batch_size do
      {sent, failed} = dispatch_batch(Enum.reverse(new_pending), state.adapter)
      {:noreply, %{state | pending: [], total_sent: state.total_sent + sent, total_failed: state.total_failed + failed}}
    else
      {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl GenServer
  def handle_call(:flush_now, _from, state) do
    {sent, failed} = dispatch_batch(Enum.reverse(state.pending), state.adapter)
    result = %{sent: sent, failed: failed}
    new_state = %{state | pending: [], total_sent: state.total_sent + sent, total_failed: state.total_failed + failed}
    {:reply, {:ok, result}, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      pending: length(state.pending),
      total_sent: state.total_sent,
      total_failed: state.total_failed
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, %{pending: []} = state) do
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    {sent, failed} = dispatch_batch(Enum.reverse(state.pending), state.adapter)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | pending: [], total_sent: state.total_sent + sent, total_failed: state.total_failed + failed}}
  end

  defp dispatch_batch([], _adapter), do: {0, 0}

  defp dispatch_batch(notifications, adapter) do
    grouped = Enum.group_by(notifications, & &1.channel)

    Enum.reduce(grouped, {0, 0}, fn {channel, group}, {ok_acc, err_acc} ->
      case adapter.send_batch(channel, group) do
        {:ok, count} ->
          {ok_acc + count, err_acc}

        {:error, reason} ->
          Logger.error("Batch send failed for channel #{channel}: #{inspect(reason)}")
          {ok_acc, err_acc + length(group)}
      end
    end)
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :scheduled_flush, interval_ms)
  end
end
```
