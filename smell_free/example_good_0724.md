```elixir
defmodule Mailer.RateLimitedSender do
  @moduledoc """
  A GenServer that enforces per-minute and per-hour send rate limits for
  outbound email, queueing excess messages and draining them as capacity
  allows.

  Prevents accidental email storms from bulk operations or runaway loops.
  The queue is bounded; messages arriving at a full queue are dropped with
  a warning rather than crashing the sender.
  """

  use GenServer

  require Logger

  alias Mailer.Adapter

  @type email :: %{to: String.t(), subject: String.t(), body_html: String.t()}
  @type enqueue_result :: :ok | {:error, :queue_full}

  @default_per_minute 60
  @default_per_hour 500
  @default_max_queue 1_000
  @drain_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueues an email for delivery within rate limits.
  Returns `:ok` or `{:error, :queue_full}` if the queue is at capacity.
  """
  @spec enqueue(email()) :: enqueue_result()
  def enqueue(%{to: _, subject: _, body_html: _} = email) do
    GenServer.call(__MODULE__, {:enqueue, email})
  end

  @doc "Returns current stats: queue depth, tokens available, and totals sent."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    state = %{
      queue: :queue.new(),
      queue_size: 0,
      max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
      per_minute_limit: Keyword.get(opts, :per_minute, @default_per_minute),
      per_hour_limit: Keyword.get(opts, :per_hour, @default_per_hour),
      minute_tokens: Keyword.get(opts, :per_minute, @default_per_minute),
      hour_tokens: Keyword.get(opts, :per_hour, @default_per_hour),
      total_sent: 0,
      total_dropped: 0,
      last_minute_refill: now_second(),
      last_hour_refill: now_second()
    }

    schedule_drain()
    schedule_refill(:minute)
    schedule_refill(:hour)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enqueue, email}, _from, %{queue_size: size, max_queue: max} = state)
      when size >= max do
    Logger.warning("[RateLimitedSender] Queue full, dropping email", to: email.to)
    {:reply, {:error, :queue_full}, %{state | total_dropped: state.total_dropped + 1}}
  end

  def handle_call({:enqueue, email}, _from, state) do
    new_state = %{state |
      queue: :queue.in(email, state.queue),
      queue_size: state.queue_size + 1
    }
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      queue_depth: state.queue_size,
      minute_tokens: state.minute_tokens,
      hour_tokens: state.hour_tokens,
      total_sent: state.total_sent,
      total_dropped: state.total_dropped
    }
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:drain, state) do
    schedule_drain()
    {:noreply, drain_one(state)}
  end

  def handle_info({:refill, :minute}, state) do
    schedule_refill(:minute)
    {:noreply, %{state | minute_tokens: state.per_minute_limit}}
  end

  def handle_info({:refill, :hour}, state) do
    schedule_refill(:hour)
    {:noreply, %{state | hour_tokens: state.per_hour_limit}}
  end

  defp drain_one(%{queue_size: 0} = state), do: state

  defp drain_one(%{minute_tokens: 0} = state) do
    Logger.debug("[RateLimitedSender] Per-minute limit reached, waiting")
    state
  end

  defp drain_one(%{hour_tokens: 0} = state) do
    Logger.debug("[RateLimitedSender] Per-hour limit reached, waiting")
    state
  end

  defp drain_one(state) do
    {{:value, email}, rest} = :queue.out(state.queue)

    case Adapter.deliver(email) do
      :ok ->
        Logger.debug("[RateLimitedSender] Sent email", to: email.to)
      {:error, reason} ->
        Logger.error("[RateLimitedSender] Delivery failed", to: email.to, reason: inspect(reason))
    end

    %{state |
      queue: rest,
      queue_size: state.queue_size - 1,
      minute_tokens: state.minute_tokens - 1,
      hour_tokens: state.hour_tokens - 1,
      total_sent: state.total_sent + 1
    }
  end

  defp schedule_drain, do: Process.send_after(self(), :drain, @drain_interval_ms)
  defp schedule_refill(:minute), do: Process.send_after(self(), {:refill, :minute}, :timer.minutes(1))
  defp schedule_refill(:hour), do: Process.send_after(self(), {:refill, :hour}, :timer.hours(1))
  defp now_second, do: System.os_time(:second)
end
```
