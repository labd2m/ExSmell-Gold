```elixir
defmodule Webhooks.DeliveryAgent do
  @moduledoc """
  Sends outbound webhook payloads to registered endpoint URLs with
  retry backoff, signature signing, and delivery status tracking.
  """

  alias Webhooks.{Repo, Delivery, SignatureSigner, EndpointRegistry}

  @max_attempts 5
  @base_backoff_ms 1_000

  @type endpoint :: %{url: String.t(), secret: String.t()}
  @type payload :: map()

  @spec deliver(Delivery.t()) :: {:ok, Delivery.t()} | {:error, atom()}
  def deliver(%Delivery{attempt_count: count}) when count >= @max_attempts do
    {:error, :max_attempts_exceeded}
  end

  def deliver(%Delivery{} = delivery) do
    endpoint = EndpointRegistry.fetch!(delivery.endpoint_id)
    signed_payload = SignatureSigner.sign(delivery.payload, endpoint.secret)

    case dispatch(endpoint.url, signed_payload) do
      {:ok, status} when status in 200..299 ->
        mark_delivered(delivery, status)

      {:ok, status} ->
        schedule_retry(delivery)
        mark_failed_attempt(delivery, status)

      {:error, reason} ->
        schedule_retry(delivery)
        mark_failed_attempt(delivery, reason)
    end
  end

  @spec dispatch(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, atom()}
  defp dispatch(url, payload) do
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]

    case HTTPoison.post(url, body, headers, recv_timeout: 5_000) do
      {:ok, %HTTPoison.Response{status_code: status}} -> {:ok, status}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end

  @spec mark_delivered(Delivery.t(), pos_integer()) ::
          {:ok, Delivery.t()} | {:error, Ecto.Changeset.t()}
  defp mark_delivered(delivery, status_code) do
    delivery
    |> Delivery.delivered_changeset(%{
      status_code: status_code,
      delivered_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec mark_failed_attempt(Delivery.t(), term()) ::
          {:ok, Delivery.t()} | {:error, Ecto.Changeset.t()}
  defp mark_failed_attempt(delivery, reason) do
    delivery
    |> Delivery.failure_changeset(%{
      attempt_count: delivery.attempt_count + 1,
      last_failure_reason: inspect(reason)
    })
    |> Repo.update()
  end

  @spec schedule_retry(Delivery.t()) :: :ok
  defp schedule_retry(delivery) do
    delay = @base_backoff_ms * :math.pow(2, delivery.attempt_count) |> round()
    Oban.insert!(Webhooks.RetryWorker.new(%{delivery_id: delivery.id}, schedule_in: delay))
    :ok
  end
end
```
