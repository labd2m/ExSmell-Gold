```elixir
defmodule Payments.TransactionSupervisor do
  @moduledoc """
  Supervises per-transaction worker processes using a DynamicSupervisor.
  Each transaction is processed in an isolated, monitored worker process.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_args) do
    DynamicSupervisor.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_worker(map()) :: DynamicSupervisor.on_start_child()
  def start_worker(transaction_params) do
    child_spec = {Payments.TransactionWorker, transaction_params}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end

defmodule Payments.TransactionWorker do
  @moduledoc """
  Handles the lifecycle of a single payment transaction:
  validation, authorization, capture, and settlement notification.
  """

  use GenServer, restart: :temporary

  alias Payments.{Gateway, Ledger, Notifier}

  @type transaction :: %{
          id: String.t(),
          amount: pos_integer(),
          currency: String.t(),
          merchant_id: String.t(),
          customer_id: String.t()
        }

  @spec start_link(transaction()) :: GenServer.on_start()
  def start_link(transaction) do
    GenServer.start_link(__MODULE__, transaction)
  end

  @impl GenServer
  def init(transaction) do
    send(self(), :process)
    {:ok, transaction}
  end

  @impl GenServer
  def handle_info(:process, transaction) do
    case run_pipeline(transaction) do
      {:ok, receipt} ->
        Notifier.send_receipt(transaction.customer_id, receipt)
        {:stop, :normal, transaction}

      {:error, reason} ->
        Notifier.send_failure(transaction.customer_id, reason)
        {:stop, :normal, transaction}
    end
  end

  @spec run_pipeline(transaction()) :: {:ok, map()} | {:error, atom()}
  defp run_pipeline(transaction) do
    with {:ok, validated} <- validate(transaction),
         {:ok, authorized} <- Gateway.authorize(validated),
         {:ok, captured} <- Gateway.capture(authorized),
         {:ok, entry} <- Ledger.record(captured) do
      {:ok, entry}
    end
  end

  @spec validate(transaction()) :: {:ok, transaction()} | {:error, :invalid_amount}
  defp validate(%{amount: amount} = transaction) when amount > 0 do
    {:ok, transaction}
  end

  defp validate(_transaction), do: {:error, :invalid_amount}
end
```
