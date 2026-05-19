```elixir
defmodule PaymentSaga do
  use GenServer

  @moduledoc """
  Orchestrates a multi-step payment transaction using a saga pattern.
  Steps: authorize → capture → reconcile → complete.
  """

  @steps [:authorize, :capture, :reconcile, :complete]

  defstruct [
    :transaction_id,
    :amount,
    :currency,
    :customer_id,
    :payment_method,
    :current_step,
    :gateway_ref,
    completed_steps: [],
    errors: []
  ]

  def start(transaction_id, attrs) do
    GenServer.start(
      __MODULE__,
      Map.put(attrs, :transaction_id, transaction_id),
      name: via(transaction_id)
    )
  end

  def advance(transaction_id) do
    GenServer.call(via(transaction_id), :advance)
  end

  def abort(transaction_id, reason) do
    GenServer.call(via(transaction_id), {:abort, reason})
  end

  def state(transaction_id) do
    GenServer.call(via(transaction_id), :state)
  end

  defp via(id), do: {:via, Registry, {PaymentRegistry, id}}

  ## Callbacks

  @impl true
  def init(attrs) do
    state = %__MODULE__{
      transaction_id: attrs.transaction_id,
      amount: attrs.amount,
      currency: Map.get(attrs, :currency, "USD"),
      customer_id: attrs.customer_id,
      payment_method: attrs.payment_method,
      current_step: hd(@steps)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:advance, _from, %{current_step: step} = state) do
    case execute_step(step, state) do
      {:ok, new_state} ->
        next = next_step(step)
        updated = %{new_state | current_step: next, completed_steps: [step | state.completed_steps]}
        {:reply, {:ok, next}, updated}

      {:error, reason} ->
        updated = %{state | errors: [{step, reason} | state.errors]}
        {:reply, {:error, reason}, updated}
    end
  end

  def handle_call({:abort, reason}, _from, state) do
    rollback(state)
    {:stop, :normal, {:aborted, reason}, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  defp execute_step(:authorize, state) do
    gateway_ref = "GW-#{state.transaction_id}-AUTH"
    {:ok, %{state | gateway_ref: gateway_ref}}
  end

  defp execute_step(:capture, state) do
    {:ok, state}
  end

  defp execute_step(:reconcile, state) do
    {:ok, state}
  end

  defp execute_step(:complete, state) do
    {:ok, %{state | current_step: :done}}
  end

  defp rollback(_state), do: :ok

  defp next_step(:authorize), do: :capture
  defp next_step(:capture), do: :reconcile
  defp next_step(:reconcile), do: :complete
  defp next_step(:complete), do: :done
  defp next_step(:done), do: :done
end

defmodule PaymentsController do
  @moduledoc "Initiates and drives payment sagas."

  def initiate(transaction_id, %{customer_id: _, amount: _, payment_method: _} = attrs) do
    case PaymentSaga.start(transaction_id, attrs) do
      {:ok, _pid} ->
        run_to_completion(transaction_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_to_completion(tid) do
    case PaymentSaga.advance(tid) do
      {:ok, :done} -> {:ok, :complete}
      {:ok, _next} -> run_to_completion(tid)
      {:error, reason} ->
        PaymentSaga.abort(tid, reason)
        {:error, reason}
    end
  end
end
```
