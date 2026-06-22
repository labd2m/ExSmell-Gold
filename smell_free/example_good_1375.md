```elixir
defmodule Ai.Inference.RequestThrottler do
  @moduledoc """
  Throttles concurrent inference requests against a model backend.
  Enforces a maximum in-flight request count and queues overflow requests
  with configurable wait timeouts.
  """

  use GenServer

  @default_max_concurrent 10
  @default_wait_timeout_ms 5_000

  @type request_id :: String.t()
  @type pending :: %{from: GenServer.from(), request_id: request_id(), enqueued_at: integer()}
  @type state :: %{
          in_flight: non_neg_integer(),
          max_concurrent: pos_integer(),
          wait_timeout_ms: pos_integer(),
          pending_queue: :queue.queue()
        }

  @doc """
  Starts the RequestThrottler linked to the calling process.

  ## Options
    - `:max_concurrent` - maximum simultaneous in-flight requests (default: 10)
    - `:wait_timeout_ms` - milliseconds a queued request waits before timing out (default: 5000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a slot for an inference request. Blocks until a slot is available
  or the wait timeout elapses.
  Returns `{:ok, request_id}` or `{:error, :timeout}`.
  """
  @spec acquire(keyword()) :: {:ok, request_id()} | {:error, :timeout}
  def acquire(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_wait_timeout_ms)
    GenServer.call(__MODULE__, :acquire, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Releases a previously acquired slot, allowing queued requests to proceed.
  """
  @spec release(request_id()) :: :ok
  def release(request_id) when is_binary(request_id) do
    GenServer.cast(__MODULE__, {:release, request_id})
  end

  @doc """
  Returns the current number of in-flight requests and queue depth.
  """
  @spec stats() :: %{in_flight: non_neg_integer(), queued: non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       in_flight: 0,
       max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
       wait_timeout_ms: Keyword.get(opts, :wait_timeout_ms, @default_wait_timeout_ms),
       pending_queue: :queue.new()
     }}
  end

  @impl GenServer
  def handle_call(:acquire, from, state) when state.in_flight < state.max_concurrent do
    request_id = generate_id()
    {:reply, {:ok, request_id}, %{state | in_flight: state.in_flight + 1}}
  end

  @impl GenServer
  def handle_call(:acquire, from, state) do
    pending = %{from: from, request_id: generate_id(), enqueued_at: System.monotonic_time(:millisecond)}
    new_queue = :queue.in(pending, state.pending_queue)
    schedule_timeout(pending.request_id, state.wait_timeout_ms)
    {:noreply, %{state | pending_queue: new_queue}}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, %{in_flight: state.in_flight, queued: :queue.len(state.pending_queue)}, state}
  end

  @impl GenServer
  def handle_cast({:release, _request_id}, state) do
    new_state = dispatch_next(%{state | in_flight: max(state.in_flight - 1, 0)})
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:acquire_timeout, request_id}, state) do
    new_queue =
      :queue.filter(fn p -> p.request_id != request_id end, state.pending_queue)

    timed_out =
      :queue.to_list(state.pending_queue)
      |> Enum.find(fn p -> p.request_id == request_id end)

    if timed_out do
      GenServer.reply(timed_out.from, {:error, :timeout})
    end

    {:noreply, %{state | pending_queue: new_queue}}
  end

  defp dispatch_next(%{pending_queue: q} = state) do
    case :queue.out(q) do
      {{:value, pending}, rest} ->
        GenServer.reply(pending.from, {:ok, pending.request_id})
        %{state | in_flight: state.in_flight + 1, pending_queue: rest}

      {:empty, _} ->
        state
    end
  end

  defp schedule_timeout(request_id, timeout_ms) do
    Process.send_after(self(), {:acquire_timeout, request_id}, timeout_ms)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
