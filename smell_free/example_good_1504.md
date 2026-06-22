```elixir
defmodule Payments.TransactionSupervisor do
  @moduledoc """
  Dynamic supervisor responsible for the lifecycle of per-transaction
  worker processes. Each worker handles the full authorization and
  settlement flow for a single payment transaction.
  """

  use DynamicSupervisor

  alias Payments.TransactionWorker

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_args) do
    DynamicSupervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised `TransactionWorker` for the given transaction params.

  Returns `{:ok, pid}` on success or `{:error, reason}` if the worker
  could not be started.
  """
  @spec start_transaction(map()) :: DynamicSupervisor.on_start_child()
  def start_transaction(%{transaction_id: _} = params) do
    child_spec = {TransactionWorker, params}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates an active transaction worker by its PID.
  """
  @spec stop_transaction(pid()) :: :ok | {:error, :not_found}
  def stop_transaction(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Returns the count of currently active transaction workers.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end
end

defmodule Payments.TransactionWorker do
  @moduledoc """
  GenServer managing the state and lifecycle of a single payment transaction.

  Handles authorization, settlement, and terminal state transitions,
  and schedules an automatic timeout if settlement is not confirmed.
  """

  use GenServer, restart: :transient

  require Logger

  @settlement_timeout_ms 30_000

  @type state :: %{
          transaction_id: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          status: :pending | :authorized | :settled | :failed
        }

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{transaction_id: id} = params) do
    GenServer.start_link(__MODULE__, params, name: via(id))
  end

  @impl GenServer
  def init(%{transaction_id: id, amount_cents: amount, currency: currency}) do
    state = %{
      transaction_id: id,
      amount_cents: amount,
      currency: currency,
      status: :pending
    }

    Process.send_after(self(), :settlement_timeout, @settlement_timeout_ms)
    {:ok, state}
  end

  @doc "Marks the transaction as authorized."
  @spec authorize(String.t()) :: :ok | {:error, :not_found}
  def authorize(transaction_id) when is_binary(transaction_id) do
    GenServer.call(via(transaction_id), :authorize)
  end

  @doc "Marks the transaction as settled."
  @spec settle(String.t()) :: :ok | {:error, :not_authorized | :not_found}
  def settle(transaction_id) when is_binary(transaction_id) do
    GenServer.call(via(transaction_id), :settle)
  end

  @impl GenServer
  def handle_call(:authorize, _from, %{status: :pending} = state) do
    {:reply, :ok, %{state | status: :authorized}}
  end

  def handle_call(:authorize, _from, state) do
    {:reply, {:error, :invalid_transition}, state}
  end

  def handle_call(:settle, _from, %{status: :authorized} = state) do
    {:reply, :ok, %{state | status: :settled}, {:continue, :stop}}
  end

  def handle_call(:settle, _from, state) do
    {:reply, {:error, :not_authorized}, state}
  end

  @impl GenServer
  def handle_continue(:stop, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(:settlement_timeout, %{status: status} = state)
      when status in [:pending, :authorized] do
    Logger.warning("Transaction #{state.transaction_id} timed out at status: #{status}")
    {:stop, :normal, %{state | status: :failed}}
  end

  def handle_info(:settlement_timeout, state) do
    {:noreply, state}
  end

  defp via(id) do
    {:via, Registry, {Payments.Registry, id}}
  end
end
```
