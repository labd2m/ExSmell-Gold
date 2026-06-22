```elixir
defmodule Fincore.Payments.ProcessorSupervisor do
  @moduledoc """
  Supervises a dynamic pool of payment processor workers.
  Each worker handles an isolated charge lifecycle and is
  started on demand under this supervisor's tree.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Fincore.Payments.WorkerSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Fincore.Payments.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @spec start_worker(String.t()) :: DynamicSupervisor.on_start_child()
  def start_worker(payment_id) when is_binary(payment_id) do
    spec = {Fincore.Payments.Worker, payment_id: payment_id}
    DynamicSupervisor.start_child(Fincore.Payments.WorkerSupervisor, spec)
  end
end

defmodule Fincore.Payments.Worker do
  @moduledoc """
  Isolated GenServer managing a single payment charge lifecycle.
  Handles authorization, capture, and settlement as distinct states.
  """

  use GenServer

  alias Fincore.Payments.Gateway

  @type payment_state :: :pending | :authorized | :captured | :settled | :failed
  @type state :: %{
          payment_id: String.t(),
          amount_cents: non_neg_integer(),
          currency: String.t(),
          status: payment_state()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    payment_id = Keyword.fetch!(opts, :payment_id)
    name = via(payment_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec authorize(String.t(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def authorize(payment_id, amount_cents, currency)
      when is_binary(payment_id) and is_integer(amount_cents) and amount_cents > 0 and
             is_binary(currency) do
    GenServer.call(via(payment_id), {:authorize, amount_cents, currency})
  end

  @spec capture(String.t()) :: :ok | {:error, String.t()}
  def capture(payment_id) when is_binary(payment_id) do
    GenServer.call(via(payment_id), :capture)
  end

  @spec settle(String.t()) :: :ok | {:error, String.t()}
  def settle(payment_id) when is_binary(payment_id) do
    GenServer.call(via(payment_id), :settle)
  end

  @impl GenServer
  def init(opts) do
    payment_id = Keyword.fetch!(opts, :payment_id)
    {:ok, %{payment_id: payment_id, amount_cents: 0, currency: "USD", status: :pending}}
  end

  @impl GenServer
  def handle_call({:authorize, amount_cents, currency}, _from, %{status: :pending} = state) do
    case Gateway.authorize(state.payment_id, amount_cents, currency) do
      {:ok, _ref} ->
        {:reply, {:ok, state.payment_id},
         %{state | amount_cents: amount_cents, currency: currency, status: :authorized}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | status: :failed}}
    end
  end

  def handle_call({:authorize, _amount, _currency}, _from, state) do
    {:reply, {:error, "payment already in status: #{state.status}"}, state}
  end

  @impl GenServer
  def handle_call(:capture, _from, %{status: :authorized} = state) do
    case Gateway.capture(state.payment_id) do
      :ok -> {:reply, :ok, %{state | status: :captured}}
      {:error, reason} -> {:reply, {:error, reason}, %{state | status: :failed}}
    end
  end

  def handle_call(:capture, _from, state) do
    {:reply, {:error, "cannot capture from status: #{state.status}"}, state}
  end

  @impl GenServer
  def handle_call(:settle, _from, %{status: :captured} = state) do
    case Gateway.settle(state.payment_id) do
      :ok -> {:reply, :ok, %{state | status: :settled}}
      {:error, reason} -> {:reply, {:error, reason}, %{state | status: :failed}}
    end
  end

  def handle_call(:settle, _from, state) do
    {:reply, {:error, "cannot settle from status: #{state.status}"}, state}
  end

  defp via(payment_id) do
    {:via, Registry, {Fincore.Payments.Registry, payment_id}}
  end
end
```
