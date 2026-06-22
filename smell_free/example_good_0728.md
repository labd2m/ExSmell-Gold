```elixir
defmodule Platform.NotificationConsolidator do
  @moduledoc """
  A GenServer that debounces and batches notifications for the same recipient
  and topic, preventing notification fatigue from rapid-fire events.

  Notifications arriving within `consolidation_window_ms` for the same
  `{recipient_id, topic}` pair are merged into a single delivery. When the
  window expires, the consolidated notification is dispatched.
  """

  use GenServer

  require Logger

  @type recipient_id :: pos_integer()
  @type topic :: atom()
  @type notification :: map()
  @type bucket_key :: {recipient_id(), topic()}

  @default_window_ms :timer.seconds(30)
  @default_max_items 20

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Adds a notification to the consolidation bucket for `{recipient_id, topic}`.
  Resets the delivery window if the bucket already exists.
  """
  @spec add(recipient_id(), topic(), notification()) :: :ok
  def add(recipient_id, topic, notification)
      when is_integer(recipient_id) and is_atom(topic) and is_map(notification) do
    GenServer.cast(__MODULE__, {:add, recipient_id, topic, notification})
  end

  @doc "Returns all pending buckets and their item counts."
  @spec pending_summary() :: [%{recipient_id: recipient_id(), topic: topic(), count: non_neg_integer()}]
  def pending_summary, do: GenServer.call(__MODULE__, :pending_summary)

  @impl GenServer
  def init(opts) do
    {:ok, %{
      buckets: %{},
      timers: %{},
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      max_items: Keyword.get(opts, :max_items, @default_max_items),
      deliver_fn: Keyword.fetch!(opts, :deliver_fn)
    }}
  end

  @impl GenServer
  def handle_cast({:add, recipient_id, topic, notification}, state) do
    key = {recipient_id, topic}
    new_state = upsert_bucket(state, key, notification)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:pending_summary, _from, %{buckets: buckets} = state) do
    summary =
      Enum.map(buckets, fn {{rid, topic}, %{items: items}} ->
        %{recipient_id: rid, topic: topic, count: length(items)}
      end)

    {:reply, summary, state}
  end

  @impl GenServer
  def handle_info({:deliver, key}, %{buckets: buckets, deliver_fn: deliver_fn} = state) do
    case Map.get(buckets, key) do
      nil ->
        {:noreply, state}

      %{recipient_id: rid, topic: topic, items: items} ->
        dispatch(deliver_fn, rid, topic, items)
        new_state = %{state |
          buckets: Map.delete(buckets, key),
          timers: Map.delete(state.timers, key)
        }
        {:noreply, new_state}
    end
  end

  defp upsert_bucket(state, key, notification) do
    {rid, topic} = key

    bucket =
      case Map.get(state.buckets, key) do
        nil -> %{recipient_id: rid, topic: topic, items: [notification]}
        existing -> %{existing | items: Enum.take([notification | existing.items], state.max_items)}
      end

    cancel_existing_timer(state, key)
    timer_ref = Process.send_after(self(), {:deliver, key}, state.window_ms)

    %{state |
      buckets: Map.put(state.buckets, key, bucket),
      timers: Map.put(state.timers, key, timer_ref)
    }
  end

  defp cancel_existing_timer(%{timers: timers}, key) do
    case Map.get(timers, key) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end
  end

  defp dispatch(deliver_fn, recipient_id, topic, items) do
    payload = %{recipient_id: recipient_id, topic: topic, items: Enum.reverse(items), count: length(items)}

    case deliver_fn.(payload) do
      :ok ->
        Logger.debug("[NotificationConsolidator] Delivered", recipient: recipient_id, topic: topic, count: length(items))
      {:error, reason} ->
        Logger.error("[NotificationConsolidator] Delivery failed", reason: inspect(reason))
    end
  end
end
```
