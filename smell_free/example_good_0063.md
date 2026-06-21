```elixir
defmodule Webhooks.Endpoint do
  @moduledoc """
  Represents a registered webhook subscriber with delivery configuration.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          secret: String.t() | nil,
          max_retries: pos_integer()
        }

  defstruct [:id, :url, :secret, max_retries: 3]

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_endpoint}
  def new(%{id: id, url: url} = params)
      when is_binary(id) and is_binary(url) do
    endpoint = struct!(__MODULE__, Map.take(params, [:id, :url, :secret, :max_retries]))
    {:ok, endpoint}
  end

  def new(_params), do: {:error, :invalid_endpoint}
end

defmodule Webhooks.DeliveryLog do
  @moduledoc false

  require Logger

  @spec record_success(String.t(), String.t(), pos_integer()) :: :ok
  def record_success(endpoint_id, topic, attempt) do
    Logger.info("Webhook delivered",
      endpoint_id: endpoint_id,
      topic: topic,
      attempt: attempt
    )
  end

  @spec record_failure(String.t(), String.t(), term()) :: :ok
  def record_failure(endpoint_id, topic, reason) do
    Logger.error("Webhook exhausted retries",
      endpoint_id: endpoint_id,
      topic: topic,
      reason: inspect(reason)
    )
  end
end

defmodule Webhooks.Dispatcher do
  @moduledoc """
  Delivers outbound webhook payloads to subscriber URLs asynchronously.

  Delivery runs inside a supervised Task so failures are isolated.
  Each attempt is retried up to `max_retries` times using exponential
  back-off. After all retries are exhausted, a structured failure entry
  is logged for later inspection.
  """

  alias Webhooks.{DeliveryLog, Endpoint}

  @type event :: %{
          required(:topic) => String.t(),
          required(:payload) => map()
        }

  @spec dispatch(Endpoint.t(), event()) :: :ok
  def dispatch(%Endpoint{} = endpoint, %{topic: _, payload: _} = event) do
    Task.Supervisor.start_child(
      Webhooks.TaskSupervisor,
      fn -> attempt_delivery(endpoint, event, 1) end
    )

    :ok
  end

  defp attempt_delivery(endpoint, event, attempt) do
    case post(endpoint.url, event.payload, build_headers(endpoint)) do
      {:ok, status} when status in 200..299 ->
        DeliveryLog.record_success(endpoint.id, event.topic, attempt)

      {:ok, status} ->
        handle_failed_attempt(endpoint, event, attempt, {:http_error, status})

      {:error, reason} ->
        handle_failed_attempt(endpoint, event, attempt, reason)
    end
  end

  defp handle_failed_attempt(endpoint, event, attempt, reason)
       when attempt < endpoint.max_retries do
    :timer.sleep(backoff_ms(attempt))
    attempt_delivery(endpoint, event, attempt + 1)
  end

  defp handle_failed_attempt(endpoint, event, _attempt, reason) do
    DeliveryLog.record_failure(endpoint.id, event.topic, reason)
  end

  defp post(url, payload, headers) do
    body = Jason.encode!(payload)

    case :httpc.request(:post, {to_charlist(url), headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_headers(%Endpoint{secret: nil}), do: []

  defp build_headers(%Endpoint{secret: secret}) do
    signature = Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    [{~c"x-webhook-signature", to_charlist(signature)}]
  end

  defp backoff_ms(attempt) do
    (:math.pow(2, attempt) |> round()) * 1_000
  end
end
```
