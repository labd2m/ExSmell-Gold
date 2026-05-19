```elixir
defmodule Notifications.Dispatcher do
  use GenServer

  @moduledoc """
  Channel-specific notification dispatch worker.
  Maintains a delivery queue per channel with retry logic and
  rate limiting toward downstream providers (e.g. Twilio, FCM, SES).
  """

  @max_retries 3
  @retry_base_ms 1_000
  @batch_size 25

  defstruct [
    :channel,
    :provider_config,
    :queue,
    :in_flight,
    :metrics
  ]

  def start_worker(channel) when channel in [:email, :sms, :push] do
    config = Application.fetch_env!(:notifications, channel)

    state = %__MODULE__{
      channel: channel,
      provider_config: config,
      queue: :queue.new(),
      in_flight: %{},
      metrics: %{sent: 0, failed: 0, retried: 0}
    }

    GenServer.start(__MODULE__, state, name: worker_name(channel))
  end

  @doc "Enqueues a notification for async dispatch on the specified channel."
  def dispatch(channel, notification) do
    GenServer.cast(worker_name(channel), {:enqueue, notification})
  end

  @doc "Returns current queue depth and delivery metrics for a channel."
  def stats(channel) do
    GenServer.call(worker_name(channel), :stats)
  end

  @doc "Flushes remaining queued notifications synchronously (for graceful shutdown)."
  def flush(channel) do
    GenServer.call(worker_name(channel), :flush, 30_000)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_drain()
    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, notification}, state) do
    new_queue = :queue.in(notification, state.queue)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      channel: state.channel,
      queued: :queue.len(state.queue),
      in_flight: map_size(state.in_flight),
      metrics: state.metrics
    }

    {:reply, stats, state}
  end

  def handle_call(:flush, _from, state) do
    {remaining, new_state} = drain_queue(state, :queue.len(state.queue))
    {:reply, {:ok, remaining}, new_state}
  end

  @impl true
  def handle_info(:drain, state) do
    {_count, new_state} = drain_queue(state, @batch_size)
    schedule_drain()
    {:noreply, new_state}
  end

  def handle_info({:retry, notification, attempt}, state) do
    case attempt < @max_retries do
      true ->
        new_state = do_send(state, notification, attempt + 1)
        {:noreply, new_state}

      false ->
        metrics = Map.update!(state.metrics, :failed, &(&1 + 1))
        {:noreply, %{state | metrics: metrics}}
    end
  end

  def handle_info({:delivery_ack, ref, :ok}, state) do
    new_in_flight = Map.delete(state.in_flight, ref)
    metrics = Map.update!(state.metrics, :sent, &(&1 + 1))
    {:noreply, %{state | in_flight: new_in_flight, metrics: metrics}}
  end

  def handle_info({:delivery_ack, ref, {:error, reason}}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{notification, attempt}, new_in_flight} ->
        delay = @retry_base_ms * :math.pow(2, attempt) |> round()
        Process.send_after(self(), {:retry, notification, attempt}, delay)
        metrics = Map.update!(state.metrics, :retried, &(&1 + 1))
        {:noreply, %{state | in_flight: new_in_flight, metrics: metrics, _reason: reason}}
    end
  end

  defp drain_queue(state, count) do
    Enum.reduce_while(1..max(count, 1), {0, state}, fn _, {n, acc} ->
      case :queue.out(acc.queue) do
        {{:value, notification}, new_queue} ->
          new_state = do_send(%{acc | queue: new_queue}, notification, 0)
          {:cont, {n + 1, new_state}}

        {:empty, _} ->
          {:halt, {n, acc}}
      end
    end)
  end

  defp do_send(state, notification, attempt) do
    ref = make_ref()
    parent = self()

    spawn(fn ->
      result = simulate_provider_send(state.channel, state.provider_config, notification)
      send(parent, {:delivery_ack, ref, result})
    end)

    new_in_flight = Map.put(state.in_flight, ref, {notification, attempt})
    %{state | in_flight: new_in_flight}
  end

  defp simulate_provider_send(_channel, _config, _notification), do: :ok

  defp schedule_drain do
    Process.send_after(self(), :drain, 500)
  end

  defp worker_name(channel) do
    Module.concat(__MODULE__, channel |> Atom.to_string() |> String.capitalize())
  end
end
```
