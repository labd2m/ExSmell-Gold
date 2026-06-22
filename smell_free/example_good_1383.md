```elixir
defmodule Platform.Webhooks.DeliveryManager do
  @moduledoc """
  Manages outbound webhook deliveries with retry logic and delivery receipts.
  Each delivery attempt is recorded; failures are retried with exponential backoff
  up to a configured maximum attempt count.
  """

  use GenServer

  @max_attempts 5
  @base_delay_ms 500

  @type webhook_id :: String.t()
  @type delivery_id :: String.t()
  @type attempt_status :: :pending | :success | :failed
  @type attempt :: %{
          number: pos_integer(),
          status: attempt_status(),
          http_status: non_neg_integer() | nil,
          attempted_at: DateTime.t()
        }
  @type delivery :: %{
          id: delivery_id(),
          webhook_id: webhook_id(),
          payload: map(),
          attempts: [attempt()],
          final_status: :pending | :delivered | :exhausted
        }

  @doc """
  Starts the DeliveryManager linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a new webhook delivery. Returns `{:ok, delivery_id}`.
  """
  @spec enqueue(webhook_id(), map()) :: {:ok, delivery_id()} | {:error, String.t()}
  def enqueue(webhook_id, payload) when is_binary(webhook_id) and is_map(payload) do
    GenServer.call(__MODULE__, {:enqueue, webhook_id, payload})
  end

  def enqueue(_webhook_id, _payload), do: {:error, "webhook_id must be a string and payload a map"}

  @doc """
  Returns the delivery record for `delivery_id`.
  """
  @spec fetch(delivery_id()) :: {:ok, delivery()} | {:error, :not_found}
  def fetch(delivery_id) when is_binary(delivery_id) do
    GenServer.call(__MODULE__, {:fetch, delivery_id})
  end

  @impl GenServer
  def init(opts) do
    http_client = Keyword.get(opts, :http_client, Platform.Webhooks.HttpClient)
    {:ok, %{deliveries: %{}, http_client: http_client}}
  end

  @impl GenServer
  def handle_call({:enqueue, webhook_id, payload}, _from, state) do
    id = Ecto.UUID.generate()

    delivery = %{
      id: id,
      webhook_id: webhook_id,
      payload: payload,
      attempts: [],
      final_status: :pending
    }

    schedule_attempt(id, 0)
    {:reply, {:ok, id}, %{state | deliveries: Map.put(state.deliveries, id, delivery)}}
  end

  @impl GenServer
  def handle_call({:fetch, delivery_id}, _from, state) do
    case Map.fetch(state.deliveries, delivery_id) do
      {:ok, delivery} -> {:reply, {:ok, delivery}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_info({:attempt, delivery_id}, state) do
    case Map.fetch(state.deliveries, delivery_id) do
      :error ->
        {:noreply, state}

      {:ok, delivery} ->
        attempt_number = length(delivery.attempts) + 1
        result = state.http_client.post(delivery.webhook_id, delivery.payload)
        updated_delivery = record_attempt(delivery, attempt_number, result)
        new_state = %{state | deliveries: Map.put(state.deliveries, delivery_id, updated_delivery)}
        maybe_schedule_retry(updated_delivery)
        {:noreply, new_state}
    end
  end

  defp record_attempt(delivery, number, {:ok, http_status}) do
    attempt = %{number: number, status: :success, http_status: http_status, attempted_at: DateTime.utc_now()}
    %{delivery | attempts: delivery.attempts ++ [attempt], final_status: :delivered}
  end

  defp record_attempt(delivery, number, {:error, _reason}) do
    attempt = %{number: number, status: :failed, http_status: nil, attempted_at: DateTime.utc_now()}
    updated = %{delivery | attempts: delivery.attempts ++ [attempt]}

    if number >= @max_attempts do
      %{updated | final_status: :exhausted}
    else
      updated
    end
  end

  defp maybe_schedule_retry(%{final_status: :pending, attempts: attempts} = delivery) do
    attempt_count = length(attempts)

    if attempt_count < @max_attempts do
      delay = @base_delay_ms * Integer.pow(2, attempt_count - 1)
      schedule_attempt(delivery.id, delay)
    end
  end

  defp maybe_schedule_retry(_delivery), do: :ok

  defp schedule_attempt(delivery_id, delay_ms) do
    Process.send_after(self(), {:attempt, delivery_id}, delay_ms)
  end
end
```
