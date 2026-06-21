# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `OrderAggregateTask` — `Task` maintaining persistent aggregate state
- **Affected function(s):** `start_aggregate/2`, `aggregate_loop/1`
- **Short explanation:** The `Task` here acts as a long-lived process that applies domain events, handles command messages, produces replies, and manages state — all hallmarks of a `GenServer` (or a purpose-built aggregate server), not a one-shot task.

```elixir
defmodule MyApp.OrderAggregateTask do
  @moduledoc """
  Event-sourced aggregate for an Order, handling command dispatch
  and projecting state from domain events.
  """

  alias MyApp.{EventStore, Repo}
  alias MyApp.Orders.Events.{
    OrderPlaced,
    OrderConfirmed,
    OrderShipped,
    OrderCancelled,
    ItemAdded,
    ItemRemoved
  }

  @valid_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:shipped, :cancelled],
    shipped: [],
    cancelled: []
  }

  def start_aggregate(order_id, initial_events) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because a Task is used to model a long-lived
    # aggregate process that receives commands, applies events, validates state
    # transitions, and replies to callers — a stateful server with multiple
    # message types. A Task is only appropriate for isolated async work;
    # a GenServer is the correct tool for this pattern.
    Task.start_link(fn ->
      initial_state = Enum.reduce(initial_events, blank_state(order_id), &apply_event/2)
      aggregate_loop(initial_state)
    end)
  end

  defp blank_state(order_id) do
    %{
      order_id: order_id,
      status: :pending,
      items: [],
      total_cents: 0,
      version: 0,
      events: []
    }
  end

  defp aggregate_loop(state) do
    receive do
      {:command, from, {:add_item, item}} ->
        if state.status == :pending do
          event = %ItemAdded{order_id: state.order_id, item: item, at: DateTime.utc_now()}
          new_state = apply_event(event, state)
          EventStore.append(event)
          send(from, {:ok, new_state.items})
          aggregate_loop(new_state)
        else
          send(from, {:error, {:invalid_status, state.status}})
          aggregate_loop(state)
        end

      {:command, from, {:remove_item, item_id}} ->
        if state.status == :pending do
          case Enum.find(state.items, &(&1.id == item_id)) do
            nil ->
              send(from, {:error, :item_not_found})
              aggregate_loop(state)

            item ->
              event = %ItemRemoved{order_id: state.order_id, item: item, at: DateTime.utc_now()}
              new_state = apply_event(event, state)
              EventStore.append(event)
              send(from, {:ok, new_state.items})
              aggregate_loop(new_state)
          end
        else
          send(from, {:error, {:invalid_status, state.status}})
          aggregate_loop(state)
        end

      {:command, from, :confirm} ->
        if :confirmed in Map.get(@valid_transitions, state.status, []) do
          event = %OrderConfirmed{order_id: state.order_id, at: DateTime.utc_now()}
          new_state = apply_event(event, state)
          EventStore.append(event)
          send(from, {:ok, :confirmed})
          aggregate_loop(new_state)
        else
          send(from, {:error, {:invalid_transition, state.status, :confirmed}})
          aggregate_loop(state)
        end

      {:command, from, :ship} ->
        if :shipped in Map.get(@valid_transitions, state.status, []) do
          event = %OrderShipped{order_id: state.order_id, at: DateTime.utc_now()}
          new_state = apply_event(event, state)
          EventStore.append(event)
          send(from, {:ok, :shipped})
          aggregate_loop(new_state)
        else
          send(from, {:error, {:invalid_transition, state.status, :shipped}})
          aggregate_loop(state)
        end

      {:command, from, {:cancel, reason}} ->
        if :cancelled in Map.get(@valid_transitions, state.status, []) do
          event = %OrderCancelled{order_id: state.order_id, reason: reason, at: DateTime.utc_now()}
          new_state = apply_event(event, state)
          EventStore.append(event)
          send(from, {:ok, :cancelled})
          aggregate_loop(new_state)
        else
          send(from, {:error, {:invalid_transition, state.status, :cancelled}})
          aggregate_loop(state)
        end

      {:get_state, from} ->
        send(from, {:ok, state})
        aggregate_loop(state)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  defp apply_event(%OrderPlaced{} = e, state),
    do: %{state | status: :pending, version: state.version + 1}

  defp apply_event(%OrderConfirmed{}, state),
    do: %{state | status: :confirmed, version: state.version + 1}

  defp apply_event(%OrderShipped{}, state),
    do: %{state | status: :shipped, version: state.version + 1}

  defp apply_event(%OrderCancelled{}, state),
    do: %{state | status: :cancelled, version: state.version + 1}

  defp apply_event(%ItemAdded{item: item}, state) do
    %{
      state
      | items: [item | state.items],
        total_cents: state.total_cents + item.unit_price_cents,
        version: state.version + 1
    }
  end

  defp apply_event(%ItemRemoved{item: item}, state) do
    %{
      state
      | items: Enum.reject(state.items, &(&1.id == item.id)),
        total_cents: state.total_cents - item.unit_price_cents,
        version: state.version + 1
    }
  end

  def send_command(pid, command) do
    send(pid, {:command, self(), command})

    receive do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
