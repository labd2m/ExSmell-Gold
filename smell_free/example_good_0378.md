```elixir
defmodule Webhooks.DeliveryWorker do
  @moduledoc """
  An Oban worker responsible for delivering a single webhook event to a
  subscriber's endpoint. Each attempt signs the payload with the subscriber's
  HMAC secret, records the attempt outcome, and updates the endpoint's health
  status. Oban's built-in retry semantics provide exponential back-off between
  attempts; the worker focuses solely on one delivery and its bookkeeping.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 8,
    unique: [period: 300, fields: [:args]]

  alias Webhooks.{AttemptLog, Endpoint, Events, Repo}

  require Logger

  @request_timeout_ms 10_000
  @success_statuses 200..299

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "endpoint_id" => endpoint_id}} = job) do
    with {:ok, event}     <- fetch_event(event_id),
         {:ok, endpoint}  <- fetch_enabled_endpoint(endpoint_id),
         {:ok, response}  <- attempt_delivery(event, endpoint, event_id, endpoint_id, job.attempt),
         :ok              <- log_attempt(event_id, endpoint_id, job.attempt, response, :success) do
      update_endpoint_health(endpoint, :success)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # With-step wrappers
  # ---------------------------------------------------------------------------

  @spec fetch_event(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp fetch_event(event_id) do
    case Events.fetch(event_id) do
      {:ok, event}     -> {:ok, event}
      {:error, reason} -> {:error, "event fetch failed: #{inspect(reason)}"}
    end
  end

  @spec fetch_enabled_endpoint(String.t()) :: {:ok, Endpoint.t()} | {:error, String.t()}
  defp fetch_enabled_endpoint(endpoint_id) do
    case Repo.get(Endpoint, endpoint_id) do
      %Endpoint{enabled: true} = ep ->
        {:ok, ep}

      %Endpoint{enabled: false} ->
        Logger.info("Skipping delivery; endpoint disabled", endpoint_id: endpoint_id)
        {:error, :skip}

      nil ->
        {:error, "endpoint #{endpoint_id} not found"}
    end
  end

  @spec attempt_delivery(map(), Endpoint.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Req.Response.t()} | {:error, String.t()}
  defp attempt_delivery(event, endpoint, event_id, endpoint_id, attempt) do
    case deliver(event, endpoint) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{status: status} = response} ->
        log_attempt(event_id, endpoint_id, attempt, response, :failure)
        endpoint_id |> fetch_endpoint_unsafe() |> update_endpoint_health(:failure)
        {:error, "HTTP #{status}"}

      {:error, {:transport, reason}} ->
        log_attempt(event_id, endpoint_id, attempt, %{}, {:transport_error, reason})
        {:error, "Transport: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec deliver(map(), Endpoint.t()) ::
          {:ok, Req.Response.t()} | {:error, map()} | {:error, {:transport, term()}}
  defp deliver(event, endpoint) do
    body      = Jason.encode!(event.payload)
    signature = sign_payload(body, endpoint.secret)
    headers   = build_headers(signature, event)

    case Req.post(endpoint.url, body: body, headers: headers, receive_timeout: @request_timeout_ms) do
      {:ok, %Req.Response{status: status} = resp} when status in @success_statuses ->
        {:ok, resp}

      {:ok, %Req.Response{} = resp} ->
        {:error, %{status: resp.status, body: resp.body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  @spec fetch_endpoint_unsafe(String.t()) :: Endpoint.t() | nil
  defp fetch_endpoint_unsafe(endpoint_id), do: Repo.get(Endpoint, endpoint_id)

  @spec sign_payload(binary(), binary()) :: String.t()
  defp sign_payload(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  @spec build_headers(String.t(), map()) :: [{String.t(), String.t()}]
  defp build_headers(signature, event) do
    [
      {"content-type", "application/json"},
      {"x-webhook-signature", "sha256=#{signature}"},
      {"x-webhook-event", event.event_type},
      {"x-webhook-delivery", event.id},
      {"x-webhook-timestamp", DateTime.to_unix(event.inserted_at) |> to_string()}
    ]
  end

  @spec log_attempt(String.t(), String.t(), pos_integer(), map(), atom() | tuple()) :: :ok
  defp log_attempt(event_id, endpoint_id, attempt_number, response, status) do
    %AttemptLog{}
    |> AttemptLog.changeset(%{
      event_id:        event_id,
      endpoint_id:     endpoint_id,
      attempt_number:  attempt_number,
      status:          status,
      response_status: Map.get(response, :status),
      response_body:   Map.get(response, :body)
    })
    |> Repo.insert()
    |> case do
      {:ok, _}         -> :ok
      {:error, reason} ->
        Logger.warning("Failed to record delivery attempt", reason: inspect(reason))
        :ok
    end
  end

  @spec update_endpoint_health(Endpoint.t() | nil, atom()) :: any()
  defp update_endpoint_health(nil, _outcome), do: :ok

  defp update_endpoint_health(%Endpoint{} = endpoint, outcome) do
    endpoint
    |> Endpoint.health_changeset(outcome)
    |> Repo.update()
  end
end
```
