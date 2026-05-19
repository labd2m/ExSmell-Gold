# Annotated Example 11 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Orders.SagaCoordinator.start/1`
- **Affected function(s):** `start/1`
- **Short explanation:** Each order in a distributed saga (reserve inventory → charge payment → dispatch) gets its own long-running GenServer started via `GenServer.start/3` outside a supervision tree. A crash mid-saga leaves the order in an inconsistent state with no automatic recovery or compensation.

```elixir
defmodule Orders.SagaCoordinator do
  use GenServer

  @moduledoc """
  Coordinates the multi-step order fulfillment saga for a single order.
  Steps: validate → reserve_inventory → charge_payment → dispatch_shipment → confirm.
  On step failure, executes compensating transactions in reverse order.
  """

  @step_timeout_ms 10_000

  @steps [:validate, :reserve_inventory, :charge_payment, :dispatch_shipment, :confirm]

  defstruct [
    :order_id,
    :order,
    :current_step,
    :completed_steps,
    :compensation_log,
    :status,
    :error
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a long-running
  # saga coordinator process for each order outside any supervision tree. Saga
  # coordinators manage critical transactional state across multiple services. If
  # this process crashes mid-saga (e.g., during payment capture), the order is left
  # partially processed. Without a supervisor, the saga never resumes and no
  # compensation steps are run, resulting in inventory reserved but payment never
  # charged, or payment charged but shipment never dispatched.
  def start(order) do
    state = %__MODULE__{
      order_id: order.id,
      order: order,
      current_step: nil,
      completed_steps: [],
      compensation_log: [],
      status: :pending,
      error: nil
    }

    GenServer.start(__MODULE__, state, name: via_name(order.id))
  end
  # VALIDATION: SMELL END

  @doc "Begins executing the saga for this order."
  def execute(order_id) do
    GenServer.cast(via_name(order_id), :execute)
  end

  @doc "Returns the current saga state for an order."
  def status(order_id) do
    GenServer.call(via_name(order_id), :status)
  end

  @doc "Manually triggers compensation if the saga is in a failed state."
  def compensate(order_id) do
    GenServer.cast(via_name(order_id), :compensate)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast(:execute, state) do
    new_state = run_step(state, :validate)
    {:noreply, new_state}
  end

  def handle_cast(:compensate, %{status: :failed} = state) do
    new_state = run_compensations(state)
    {:noreply, new_state}
  end

  def handle_cast(:compensate, state), do: {:noreply, state}

  @impl true
  def handle_info({:step_result, step, {:ok, result}}, state) do
    new_completed = [{step, result} | state.completed_steps]

    new_state = %{state | completed_steps: new_completed, current_step: nil}

    case next_step(step) do
      nil ->
        {:noreply, %{new_state | status: :completed}}

      next ->
        {:noreply, run_step(new_state, next)}
    end
  end

  def handle_info({:step_result, step, {:error, reason}}, state) do
    failed_state = %{
      state
      | status: :failed,
        current_step: nil,
        error: {step, reason}
    }

    compensated_state = run_compensations(failed_state)
    {:noreply, compensated_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    summary = %{
      order_id: state.order_id,
      status: state.status,
      current_step: state.current_step,
      completed_steps: Enum.map(state.completed_steps, fn {step, _} -> step end),
      compensation_log: state.compensation_log,
      error: state.error
    }

    {:reply, summary, state}
  end

  defp run_step(state, step) do
    parent = self()

    Task.start(fn ->
      result =
        case step do
          :validate -> validate_order(state.order)
          :reserve_inventory -> reserve_inventory(state.order)
          :charge_payment -> charge_payment(state.order)
          :dispatch_shipment -> dispatch_shipment(state.order)
          :confirm -> confirm_order(state.order)
        end

      send(parent, {:step_result, step, result})
    end)

    %{state | current_step: step, status: :running}
  end

  defp run_compensations(state) do
    log =
      Enum.map(state.completed_steps, fn {step, data} ->
        result = compensate_step(step, state.order, data)
        {step, result}
      end)

    %{state | compensation_log: log, status: :compensated}
  end

  defp next_step(current) do
    idx = Enum.find_index(@steps, &(&1 == current))
    Enum.at(@steps, idx + 1)
  end

  defp validate_order(_order), do: {:ok, :valid}
  defp reserve_inventory(_order), do: {:ok, %{reservation_id: "res_123"}}
  defp charge_payment(_order), do: {:ok, %{charge_id: "ch_456"}}
  defp dispatch_shipment(_order), do: {:ok, %{shipment_id: "ship_789"}}
  defp confirm_order(_order), do: {:ok, :confirmed}
  defp compensate_step(_step, _order, _data), do: :ok

  defp via_name(order_id) do
    {:via, Registry, {Orders.SagaRegistry, order_id}}
  end
end
```
