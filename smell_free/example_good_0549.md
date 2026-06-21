# File: `example_good_549.md`

```elixir
defmodule Monitoring.SLATracker do
  @moduledoc """
  GenServer that tracks open work items against their SLA deadlines,
  broadcasting breach events when a deadline is crossed and summary
  warnings as items approach their deadlines.

  Items are registered with a deadline. The tracker evaluates all open
  items on a configurable polling interval and notifies a handler module
  of state transitions, rather than sending one notification per poll.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @pubsub MyApp.PubSub
  @sla_topic "sla:events"
  @default_poll_interval_ms 60_000
  @default_warning_threshold_minutes 30

  @type item_id :: String.t()
  @type sla_status :: :on_track | :at_risk | :breached

  @type tracked_item :: %{
          id: item_id(),
          deadline: DateTime.t(),
          status: sla_status(),
          notified_at_risk: boolean(),
          notified_breached: boolean()
        }

  @type opts :: [
          poll_interval_ms: pos_integer(),
          warning_threshold_minutes: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a work item with its SLA deadline.

  Returns `:ok` or `{:error, :already_tracked}`.
  """
  @spec track(item_id(), DateTime.t()) :: :ok | {:error, :already_tracked}
  def track(item_id, %DateTime{} = deadline) when is_binary(item_id) do
    GenServer.call(__MODULE__, {:track, item_id, deadline})
  end

  @doc """
  Removes a resolved item from tracking.
  """
  @spec resolve(item_id()) :: :ok
  def resolve(item_id) when is_binary(item_id) do
    GenServer.cast(__MODULE__, {:resolve, item_id})
  end

  @doc """
  Returns all currently tracked items with their SLA status.
  """
  @spec all_items() :: [tracked_item()]
  def all_items do
    GenServer.call(__MODULE__, :all_items)
  end

  @doc """
  Returns items currently in breach of their SLA deadline.
  """
  @spec breached_items() :: [tracked_item()]
  def breached_items do
    GenServer.call(__MODULE__, :breached_items)
  end

  @doc """
  Returns items at risk of breaching within the warning threshold.
  """
  @spec at_risk_items() :: [tracked_item()]
  def at_risk_items do
    GenServer.call(__MODULE__, :at_risk_items)
  end

  @impl GenServer
  def init(opts) do
    poll_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    warn_mins = Keyword.get(opts, :warning_threshold_minutes, @default_warning_threshold_minutes)
    schedule_poll(poll_ms)
    {:ok, %{items: %{}, poll_interval_ms: poll_ms, warning_threshold_minutes: warn_mins}}
  end

  @impl GenServer
  def handle_call({:track, id, deadline}, _from, state) do
    if Map.has_key?(state.items, id) do
      {:reply, {:error, :already_tracked}, state}
    else
      item = %{id: id, deadline: deadline, status: :on_track,
               notified_at_risk: false, notified_breached: false}
      {:reply, :ok, put_in(state, [:items, id], item)}
    end
  end

  @impl GenServer
  def handle_call(:all_items, _from, state) do
    {:reply, Map.values(state.items), state}
  end

  @impl GenServer
  def handle_call(:breached_items, _from, state) do
    items = state.items |> Map.values() |> Enum.filter(&(&1.status == :breached))
    {:reply, items, state}
  end

  @impl GenServer
  def handle_call(:at_risk_items, _from, state) do
    items = state.items |> Map.values() |> Enum.filter(&(&1.status == :at_risk))
    {:reply, items, state}
  end

  @impl GenServer
  def handle_cast({:resolve, id}, state) do
    {:noreply, update_in(state, [:items], &Map.delete(&1, id))}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    now = DateTime.utc_now()
    warn_cutoff = DateTime.add(now, state.warning_threshold_minutes * 60, :second)

    new_items =
      Map.new(state.items, fn {id, item} ->
        updated = evaluate_item(item, now, warn_cutoff)
        {id, updated}
      end)

    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | items: new_items}}
  end

  defp evaluate_item(%{deadline: dl} = item, now, warn_cutoff) do
    cond do
      DateTime.compare(dl, now) == :lt ->
        maybe_notify_breached(item)

      DateTime.compare(dl, warn_cutoff) == :lt ->
        maybe_notify_at_risk(item)

      true ->
        %{item | status: :on_track}
    end
  end

  defp maybe_notify_breached(%{notified_breached: true} = item), do: %{item | status: :breached}

  defp maybe_notify_breached(item) do
    PubSub.broadcast(@pubsub, @sla_topic, {:sla_breached, item.id, item.deadline})
    Logger.warning("SLA breached for item #{item.id}")
    %{item | status: :breached, notified_breached: true}
  end

  defp maybe_notify_at_risk(%{notified_at_risk: true} = item), do: %{item | status: :at_risk}

  defp maybe_notify_at_risk(item) do
    PubSub.broadcast(@pubsub, @sla_topic, {:sla_at_risk, item.id, item.deadline})
    %{item | status: :at_risk, notified_at_risk: true}
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
