```elixir
defmodule Deadline.Operation do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          caller: pid(),
          label: String.t(),
          deadline_at: integer(),
          timer_ref: reference()
        }

  defstruct [:id, :caller, :label, :deadline_at, :timer_ref]
end

defmodule Deadline.Enforcer do
  @moduledoc """
  Monitors named in-flight operations and notifies callers when their
  declared deadline elapses without completion.

  Callers register an operation with a timeout before starting work and
  deregister it on completion. If the deadline fires before deregistration,
  the caller receives `{:deadline_exceeded, operation_id, label}`. The
  notification is non-preemptive: callers decide how to handle the message
  (abort, log, emit a metric). This keeps the enforcer decoupled from any
  specific cancellation strategy.
  """

  use GenServer

  alias Deadline.Operation

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), pos_integer(), pid()) :: {:ok, String.t()}
  def register(label, timeout_ms, caller \\ self())
      when is_binary(label) and is_integer(timeout_ms) and timeout_ms > 0 and is_pid(caller) do
    GenServer.call(__MODULE__, {:register, label, timeout_ms, caller})
  end

  @spec complete(String.t()) :: :ok | {:error, :not_found}
  def complete(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:complete, operation_id})
  end

  @spec active_operations() :: [%{id: String.t(), label: String.t(), remaining_ms: integer()}]
  def active_operations do
    GenServer.call(__MODULE__, :active_operations)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{operations: %{}}}

  @impl GenServer
  def handle_call({:register, label, timeout_ms, caller}, _from, state) do
    id = generate_id()
    now = System.monotonic_time(:millisecond)
    timer_ref = Process.send_after(self(), {:deadline_fired, id}, timeout_ms)

    op = %Operation{
      id: id,
      caller: caller,
      label: label,
      deadline_at: now + timeout_ms,
      timer_ref: timer_ref
    }

    {:reply, {:ok, id}, %{state | operations: Map.put(state.operations, id, op)}}
  end

  def handle_call({:complete, id}, _from, state) do
    case Map.fetch(state.operations, id) do
      {:ok, op} ->
        Process.cancel_timer(op.timer_ref)
        {:reply, :ok, %{state | operations: Map.delete(state.operations, id)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:active_operations, _from, state) do
    now = System.monotonic_time(:millisecond)

    ops =
      Enum.map(state.operations, fn {_id, op} ->
        %{id: op.id, label: op.label, remaining_ms: max(0, op.deadline_at - now)}
      end)

    {:reply, ops, state}
  end

  @impl GenServer
  def handle_info({:deadline_fired, id}, state) do
    case Map.fetch(state.operations, id) do
      {:ok, op} ->
        send(op.caller, {:deadline_exceeded, op.id, op.label})
        {:noreply, %{state | operations: Map.delete(state.operations, id)}}

      :error ->
        {:noreply, state}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

defmodule Deadline.Guard do
  @moduledoc """
  Convenience wrapper that registers a deadline, runs a function, and
  completes or abandons the registration based on the outcome.
  """

  alias Deadline.Enforcer

  @spec with_deadline(String.t(), pos_integer(), (-> term())) :: term()
  def with_deadline(label, timeout_ms, fun)
      when is_binary(label) and is_function(fun, 0) do
    {:ok, op_id} = Enforcer.register(label, timeout_ms)

    try do
      result = fun.()
      Enforcer.complete(op_id)
      result
    rescue
      error ->
        Enforcer.complete(op_id)
        reraise error, __STACKTRACE__
    end
  end
end
```
