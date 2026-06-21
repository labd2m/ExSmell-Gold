# File: `example_good_16.md`

```elixir
defmodule Mailer.DeliveryWorker do
  @moduledoc """
  Supervised GenServer responsible for draining an in-process email
  delivery queue. Emails are enqueued from any process and dispatched
  through the configured adapter in the order they were received.

  The worker uses a bounded queue to apply back-pressure; callers
  receive `{:error, :queue_full}` rather than silently growing the queue.
  """

  use GenServer

  require Logger

  alias Mailer.Email

  @default_max_queue 500
  @default_batch_size 20
  @dispatch_interval_ms 500

  @type opts :: [
          adapter: module(),
          max_queue: pos_integer(),
          batch_size: pos_integer()
        ]

  @type enqueue_result :: :ok | {:error, :queue_full}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds an email to the delivery queue.

  Returns `:ok` if enqueued successfully, or `{:error, :queue_full}` if
  the worker's queue has reached its configured maximum depth.
  """
  @spec enqueue(Email.t()) :: enqueue_result()
  def enqueue(%Email{} = email) do
    GenServer.call(__MODULE__, {:enqueue, email})
  end

  @doc """
  Returns current queue depth and cumulative delivery statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    schedule_dispatch()

    {:ok,
     %{
       adapter: adapter,
       max_queue: max_queue,
       batch_size: batch_size,
       queue: :queue.new(),
       queue_size: 0,
       sent: 0,
       failed: 0
     }}
  end

  @impl GenServer
  def handle_call({:enqueue, email}, _from, state) do
    if state.queue_size >= state.max_queue do
      {:reply, {:error, :queue_full}, state}
    else
      new_queue = :queue.in(email, state.queue)
      {:reply, :ok, %{state | queue: new_queue, queue_size: state.queue_size + 1}}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      queued: state.queue_size,
      sent: state.sent,
      failed: state.failed
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:dispatch, state) do
    new_state = drain_batch(state)
    schedule_dispatch()
    {:noreply, new_state}
  end

  defp drain_batch(state) do
    {batch, remaining_queue, drained_count} = take_batch(state.queue, state.batch_size)

    {sent, failed} = dispatch_emails(batch, state.adapter)

    %{state
      | queue: remaining_queue,
        queue_size: state.queue_size - drained_count,
        sent: state.sent + sent,
        failed: state.failed + failed}
  end

  defp take_batch(queue, batch_size) do
    Enum.reduce_while(1..batch_size, {[], queue, 0}, fn _n, {batch, q, count} ->
      case :queue.out(q) do
        {{:value, email}, rest} -> {:cont, {[email | batch], rest, count + 1}}
        {:empty, _} -> {:halt, {batch, q, count}}
      end
    end)
  end

  defp dispatch_emails(emails, adapter) do
    Enum.reduce(emails, {0, 0}, fn email, {ok_count, err_count} ->
      case adapter.deliver(email) do
        :ok ->
          {ok_count + 1, err_count}

        {:error, reason} ->
          Logger.warning("Email delivery failed for #{email.to}: #{inspect(reason)}")
          {ok_count, err_count + 1}
      end
    end)
  end

  defp schedule_dispatch do
    Process.send_after(self(), :dispatch, @dispatch_interval_ms)
  end
end
```
