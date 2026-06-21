```elixir
defmodule Webhooks.DeliverySupervisor do
  @moduledoc """
  Supervises transient webhook delivery workers. Each delivery runs in its
  own isolated process, retrying independently until success or until the
  maximum attempt budget is exhausted.
  """

  use DynamicSupervisor

  alias Webhooks.DeliveryWorker

  @doc "Starts the supervisor linked to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules a new webhook delivery. `params` must include `url` and `payload`.
  Optionally accepts `max_attempts` (default: 5).
  """
  @spec schedule(map()) :: {:ok, pid()} | {:error, term()}
  def schedule(%{url: url, payload: payload} = params)
      when is_binary(url) and is_map(payload) do
    delivery = %{
      id: generate_id(),
      url: url,
      payload: payload,
      attempts: 0,
      max_attempts: Map.get(params, :max_attempts, 5),
      status: :pending
    }

    DynamicSupervisor.start_child(__MODULE__, {DeliveryWorker, delivery})
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  Manages one outbound webhook delivery with automatic exponential-backoff
  retries. On each attempt the worker sends an HTTP POST to the configured
  URL. A successful 2xx response terminates the process normally; exhausting
  the attempt budget terminates it with a shutdown reason.
  """

  use GenServer

  require Logger

  @initial_delay_ms 1_000

  @type delivery :: %{
          id: String.t(),
          url: String.t(),
          payload: map(),
          attempts: non_neg_integer(),
          max_attempts: pos_integer(),
          status: :pending | :delivered | :failed
        }

  @doc false
  @spec start_link(delivery()) :: GenServer.on_start()
  def start_link(%{id: _id} = delivery) do
    GenServer.start_link(__MODULE__, delivery)
  end

  @impl GenServer
  def init(delivery) do
    Process.send_after(self(), :attempt, 0)
    {:ok, delivery}
  end

  @impl GenServer
  def handle_info(:attempt, delivery) do
    case send_request(delivery.url, delivery.payload) do
      :ok ->
        Logger.info("[Webhooks] #{delivery.id} delivered on attempt #{delivery.attempts + 1}")
        {:stop, :normal, %{delivery | status: :delivered}}

      {:error, reason} ->
        handle_failure(delivery, reason)
    end
  end

  defp handle_failure(%{attempts: n, max_attempts: max} = delivery, reason)
       when n + 1 >= max do
    Logger.warning("[Webhooks] #{delivery.id} permanently failed: #{inspect(reason)}")
    {:stop, :normal, %{delivery | status: :failed, attempts: n + 1}}
  end

  defp handle_failure(%{attempts: n} = delivery, reason) do
    delay = trunc(@initial_delay_ms * :math.pow(2, n))
    Logger.warning("[Webhooks] #{delivery.id} attempt #{n + 1} failed, retry in #{delay}ms")
    Process.send_after(self(), :attempt, delay)
    {:noreply, %{delivery | attempts: n + 1}}
  end

  defp send_request(url, payload) do
    body = Jason.encode!(payload)
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, body, headers, recv_timeout: 5_000) do
      {:ok, %{status_code: code}} when code in 200..299 -> :ok
      {:ok, %{status_code: code}} -> {:error, {:http_status, code}}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end
end
```
