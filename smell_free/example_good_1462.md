```elixir
defmodule Webhooks.Delivery do
  @moduledoc """
  Represents a single outbound webhook delivery attempt with its outcome.
  """

  @type status :: :pending | :delivered | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          endpoint_url: String.t(),
          payload: map(),
          status: status(),
          attempt: pos_integer(),
          delivered_at: DateTime.t() | nil
        }

  defstruct [:id, :endpoint_url, :payload, :status, :attempt, :delivered_at]
end

defmodule Webhooks.Dispatcher do
  use GenServer

  alias Webhooks.Delivery

  @moduledoc """
  Dispatches outbound webhook deliveries with automatic exponential-backoff
  retry logic. Each delivery is tracked in-process and retired up to a
  configurable maximum before being marked permanently failed.
  """

  @max_attempts 5
  @base_delay_ms 500

  @type state :: %{deliveries: %{String.t() => Delivery.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec enqueue(String.t(), map()) :: {:ok, String.t()}
  def enqueue(endpoint_url, payload) when is_binary(endpoint_url) and is_map(payload) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    GenServer.cast(__MODULE__, {:enqueue, id, endpoint_url, payload})
    {:ok, id}
  end

  @spec delivery_status(String.t()) :: {:ok, Delivery.t()} | {:error, :not_found}
  def delivery_status(id) do
    GenServer.call(__MODULE__, {:status, id})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{deliveries: %{}}}
  end

  @impl GenServer
  def handle_cast({:enqueue, id, url, payload}, state) do
    delivery = %Delivery{
      id: id,
      endpoint_url: url,
      payload: payload,
      status: :pending,
      attempt: 1,
      delivered_at: nil
    }

    send(self(), {:dispatch, id})
    {:noreply, put_in(state.deliveries[id], delivery)}
  end

  @impl GenServer
  def handle_call({:status, id}, _from, state) do
    result =
      case Map.fetch(state.deliveries, id) do
        {:ok, delivery} -> {:ok, delivery}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:dispatch, id}, state) do
    case Map.fetch(state.deliveries, id) do
      {:ok, delivery} ->
        new_state = attempt_dispatch(delivery, state)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  defp attempt_dispatch(%Delivery{attempt: attempt} = delivery, state)
       when attempt > @max_attempts do
    updated = %{delivery | status: :failed}
    {:noreply, put_in(state.deliveries[delivery.id], updated)}
    |> elem(1)
    |> then(fn s -> s end)

    put_in(state.deliveries[delivery.id], updated)
  end

  defp attempt_dispatch(delivery, state) do
    case post_payload(delivery.endpoint_url, delivery.payload) do
      :ok ->
        updated = %{delivery | status: :delivered, delivered_at: DateTime.utc_now()}
        put_in(state.deliveries[delivery.id], updated)

      :error ->
        delay = @base_delay_ms * :math.pow(2, delivery.attempt - 1) |> round()
        Process.send_after(self(), {:dispatch, delivery.id}, delay)
        updated = %{delivery | attempt: delivery.attempt + 1}
        put_in(state.deliveries[delivery.id], updated)
    end
  end

  defp post_payload(url, payload) do
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]

    case Req.post(url, body: body, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> :error
    end
  end
end
```
