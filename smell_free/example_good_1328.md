**File:** `example_good_1328.md`

```elixir
defmodule Payments.ProcessorSupervisor do
  @moduledoc """
  Supervises a dynamic pool of payment processor workers.
  Each worker is started on demand and linked to this supervisor.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Payments.WorkerSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Payments.WorkerRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Payments.Worker do
  @moduledoc """
  A GenServer responsible for processing a single payment transaction.
  Holds transient state for the duration of one charge lifecycle.
  """

  use GenServer

  alias Payments.{ChargeRequest, ChargeResult, GatewayClient}

  @type state :: %{
          request: ChargeRequest.t(),
          attempts: non_neg_integer()
        }

  @max_attempts 3

  @spec start_link(ChargeRequest.t()) :: GenServer.on_start()
  def start_link(%ChargeRequest{} = request) do
    name = via_registry(request.idempotency_key)
    GenServer.start_link(__MODULE__, request, name: name)
  end

  @spec process(ChargeRequest.t()) :: {:ok, ChargeResult.t()} | {:error, term()}
  def process(%ChargeRequest{} = request) do
    with {:ok, pid} <- ensure_worker(request) do
      GenServer.call(pid, :run, :timer.seconds(30))
    end
  end

  @impl GenServer
  def init(%ChargeRequest{} = request) do
    {:ok, %{request: request, attempts: 0}}
  end

  @impl GenServer
  def handle_call(:run, _from, %{request: request, attempts: attempts} = state)
      when attempts < @max_attempts do
    case GatewayClient.charge(request) do
      {:ok, result} ->
        {:stop, :normal, {:ok, result}, state}

      {:error, :retryable} when attempts + 1 < @max_attempts ->
        {:reply, {:error, :retryable}, %{state | attempts: attempts + 1}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:run, _from, state) do
    {:stop, :normal, {:error, :max_attempts_exceeded}, state}
  end

  defp ensure_worker(request) do
    case Registry.lookup(Payments.WorkerRegistry, request.idempotency_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          Payments.WorkerSupervisor,
          {__MODULE__, request}
        )
    end
  end

  defp via_registry(key), do: {:via, Registry, {Payments.WorkerRegistry, key}}
end

defmodule Payments.ChargeRequest do
  @moduledoc "Represents a validated payment charge request."

  @enforce_keys [:idempotency_key, :amount_cents, :currency, :source_token]
  defstruct [:idempotency_key, :amount_cents, :currency, :source_token]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          source_token: String.t()
        }
end

defmodule Payments.ChargeResult do
  @moduledoc "Represents a successful charge outcome from the payment gateway."

  @enforce_keys [:transaction_id, :amount_cents, :currency, :charged_at]
  defstruct [:transaction_id, :amount_cents, :currency, :charged_at]

  @type t :: %__MODULE__{
          transaction_id: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          charged_at: DateTime.t()
        }
end
```
