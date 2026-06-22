```elixir
defmodule Webhooks.Delivery do
  @moduledoc """
  An immutable value object representing a single outbound webhook payload.
  """

  @enforce_keys [:id, :url, :payload]
  defstruct [:id, :url, :payload, headers: []]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          payload: map(),
          headers: list({String.t(), String.t()})
        }

  @spec new(String.t(), map(), list()) :: t()
  def new(url, payload, headers \\ [])
      when is_binary(url) and is_map(payload) and is_list(headers) do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      url: url,
      payload: payload,
      headers: headers
    }
  end
end

defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers a single webhook payload to its target URL with exponential backoff.
  The worker is transient: it terminates normally on success or exhausted retries.
  """

  use GenServer, restart: :transient

  require Logger

  alias Webhooks.{Delivery, HTTPClient}

  @max_attempts 5
  @base_backoff_ms 1_000

  @type state :: %{delivery: Delivery.t(), attempts: non_neg_integer()}

  @spec child_spec(Delivery.t()) :: Supervisor.child_spec()
  def child_spec(%Delivery{id: id} = delivery) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [delivery]},
      restart: :transient,
      shutdown: 30_000
    }
  end

  @spec start_link(Delivery.t()) :: GenServer.on_start()
  def start_link(%Delivery{} = delivery) do
    GenServer.start_link(__MODULE__, delivery)
  end

  @impl GenServer
  def init(%Delivery{} = delivery) do
    send(self(), :attempt)
    {:ok, %{delivery: delivery, attempts: 0}}
  end

  @impl GenServer
  def handle_info(:attempt, %{attempts: @max_attempts} = state) do
    Logger.error("Webhook delivery exhausted retries", delivery_id: state.delivery.id)
    {:stop, :normal, state}
  end

  def handle_info(:attempt, state) do
    case HTTPClient.post(state.delivery.url, state.delivery.payload, state.delivery.headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Webhook delivered", delivery_id: state.delivery.id, status: status)
        {:stop, :normal, state}

      {:ok, %{status: status}} ->
        Logger.warning("Webhook endpoint rejected", delivery_id: state.delivery.id, status: status)
        reschedule(state.attempts)
        {:noreply, Map.update!(state, :attempts, &(&1 + 1))}

      {:error, reason} ->
        Logger.warning("Webhook transport error", delivery_id: state.delivery.id, reason: reason)
        reschedule(state.attempts)
        {:noreply, Map.update!(state, :attempts, &(&1 + 1))}
    end
  end

  defp reschedule(attempt) do
    delay = @base_backoff_ms * Integer.pow(2, attempt)
    Process.send_after(self(), :attempt, delay)
  end
end

defmodule Webhooks.DeliverySupervisor do
  @moduledoc """
  Dynamically supervises in-flight webhook delivery workers.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec enqueue(Webhooks.Delivery.t()) :: {:ok, pid()} | {:error, term()}
  def enqueue(%Webhooks.Delivery{} = delivery) do
    DynamicSupervisor.start_child(__MODULE__, Webhooks.DeliveryWorker.child_spec(delivery))
  end
end
```
