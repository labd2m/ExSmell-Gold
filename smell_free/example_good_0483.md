```elixir
defmodule Readiness.Check do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          status: :pending | :ready | :failed,
          error: term() | nil,
          ready_at: integer() | nil
        }

  defstruct [:name, :error, :ready_at, status: :pending]
end

defmodule Readiness.Gate do
  @moduledoc """
  Holds callers in a waiting state until all registered service checks
  report readiness, or until a timeout elapses.

  Services call `mark_ready/1` when their startup is complete or
  `mark_failed/2` when they cannot initialise. Callers blocked on
  `await/1` are released as soon as all checks pass. If the deadline
  elapses, callers receive a `{:error, :timeout, pending_checks}` result
  listing which services did not respond in time.
  """

  use GenServer

  alias Readiness.Check

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(atom()) :: :ok
  def register(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:register, name})
  end

  @spec mark_ready(atom()) :: :ok
  def mark_ready(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:mark_ready, name})
  end

  @spec mark_failed(atom(), term()) :: :ok
  def mark_failed(name, reason) when is_atom(name) do
    GenServer.cast(__MODULE__, {:mark_failed, name, reason})
  end

  @spec await(pos_integer()) ::
          :ok | {:error, :timeout, [atom()]} | {:error, :checks_failed, [atom()]}
  def await(timeout_ms \\ 30_000) when is_integer(timeout_ms) do
    GenServer.call(__MODULE__, :await, timeout_ms)
  rescue
    _ -> {:error, :timeout, pending_checks()}
  end

  @spec status() :: %{atom() => :pending | :ready | :failed}
  def status, do: GenServer.call(__MODULE__, :status)

  defp pending_checks do
    case GenServer.call(__MODULE__, :pending_names) do
      names -> names
    end
  rescue
    _ -> [:unknown]
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{checks: %{}, waiters: []}}
  end

  @impl GenServer
  def handle_call({:register, name}, _from, state) do
    check = %Check{name: name}
    {:reply, :ok, %{state | checks: Map.put(state.checks, name, check)}}
  end

  def handle_call(:await, from, state) do
    case evaluate(state.checks) do
      :all_ready -> {:reply, :ok, state}
      {:failed, names} -> {:reply, {:error, :checks_failed, names}, state}
      :pending -> {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:status, _from, state) do
    status_map = Map.new(state.checks, fn {name, check} -> {name, check.status} end)
    {:reply, status_map, state}
  end

  def handle_call(:pending_names, _from, state) do
    names = state.checks |> Enum.filter(fn {_, c} -> c.status == :pending end) |> Enum.map(&elem(&1, 0))
    {:reply, names, state}
  end

  @impl GenServer
  def handle_cast({:mark_ready, name}, state) do
    updated_check = %Check{name: name, status: :ready, ready_at: System.monotonic_time(:millisecond)}
    new_state = %{state | checks: Map.put(state.checks, name, updated_check)}
    {:noreply, notify_waiters(new_state)}
  end

  def handle_cast({:mark_failed, name, reason}, state) do
    updated_check = %Check{name: name, status: :failed, error: reason}
    new_state = %{state | checks: Map.put(state.checks, name, updated_check)}
    {:noreply, notify_waiters(new_state)}
  end

  defp notify_waiters(%{waiters: []} = state), do: state

  defp notify_waiters(state) do
    case evaluate(state.checks) do
      :all_ready ->
        Enum.each(state.waiters, &GenServer.reply(&1, :ok))
        %{state | waiters: []}

      {:failed, names} ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:error, :checks_failed, names}))
        %{state | waiters: []}

      :pending ->
        state
    end
  end

  defp evaluate(checks) do
    statuses = Enum.map(checks, fn {_name, check} -> check.status end)
    failed = checks |> Enum.filter(fn {_, c} -> c.status == :failed end) |> Enum.map(&elem(&1, 0))

    cond do
      failed != [] -> {:failed, failed}
      Enum.all?(statuses, &(&1 == :ready)) -> :all_ready
      true -> :pending
    end
  end
end
```
