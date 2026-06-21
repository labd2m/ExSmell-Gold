```elixir
defmodule Webhooks.FanoutDispatcher do
  @moduledoc """
  Dispatches a single webhook event to multiple registered endpoints in
  parallel, collecting per-endpoint delivery outcomes.

  Endpoints are fetched from the database scoped to the event type.
  Each delivery runs under a Task.Supervisor with individual timeouts so
  a slow endpoint does not delay others.
  """

  alias Webhooks.{Endpoint, DeliveryLog, Repo}

  @type event_type :: String.t()
  @type payload :: map()
  @type delivery_outcome :: %{
          endpoint_id: pos_integer(),
          url: String.t(),
          status: :delivered | :failed,
          http_status: pos_integer() | nil,
          duration_ms: pos_integer()
        }
  @type dispatch_result :: %{
          event_type: event_type(),
          delivered: non_neg_integer(),
          failed: non_neg_integer(),
          outcomes: [delivery_outcome()]
        }

  @delivery_timeout_ms 10_000
  @default_concurrency 20

  @doc """
  Dispatches `payload` to all active endpoints subscribed to `event_type`.
  Returns a structured summary of all delivery outcomes.
  """
  @spec dispatch(Supervisor.supervisor(), event_type(), payload(), keyword()) :: dispatch_result()
  def dispatch(task_sup, event_type, payload, opts \\ [])
      when is_binary(event_type) and is_map(payload) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout_ms, @delivery_timeout_ms)

    endpoints = load_endpoints(event_type)
    signed_payload = sign_payload(payload)

    outcomes =
      endpoints
      |> Task.Supervisor.async_stream_nolink(
        task_sup,
        &deliver_to_endpoint(&1, signed_payload, event_type),
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(endpoints)
      |> Enum.map(&build_outcome/1)

    Enum.each(outcomes, &persist_log/1)
    summarize(event_type, outcomes)
  end

  defp load_endpoints(event_type) do
    import Ecto.Query
    from(e in Endpoint,
      where: e.active == true and ^event_type in e.subscribed_events,
      order_by: [asc: e.id]
    )
    |> Repo.all()
  end

  defp deliver_to_endpoint(%Endpoint{url: url, secret: secret}, signed_payload, event_type) do
    start = System.monotonic_time(:millisecond)
    signature = compute_signature(signed_payload, secret)

    headers = [
      {"content-type", "application/json"},
      {"x-webhook-event", event_type},
      {"x-webhook-signature", signature}
    ]

    result = Req.post(url, body: Jason.encode!(signed_payload), headers: headers, receive_timeout: 8_000)
    duration = System.monotonic_time(:millisecond) - start
    {result, duration}
  end

  defp build_outcome({{:ok, {result, duration}}, %Endpoint{id: id, url: url}}) do
    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        %{endpoint_id: id, url: url, status: :delivered, http_status: status, duration_ms: duration}

      {:ok, %{status: status}} ->
        %{endpoint_id: id, url: url, status: :failed, http_status: status, duration_ms: duration}

      {:error, _} ->
        %{endpoint_id: id, url: url, status: :failed, http_status: nil, duration_ms: duration}
    end
  end

  defp build_outcome({{:exit, _reason}, %Endpoint{id: id, url: url}}) do
    %{endpoint_id: id, url: url, status: :failed, http_status: nil, duration_ms: @delivery_timeout_ms}
  end

  defp summarize(event_type, outcomes) do
    delivered = Enum.count(outcomes, &(&1.status == :delivered))
    %{event_type: event_type, delivered: delivered, failed: length(outcomes) - delivered, outcomes: outcomes}
  end

  defp persist_log(outcome) do
    %DeliveryLog{}
    |> DeliveryLog.changeset(Map.put(outcome, :logged_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  defp sign_payload(payload) do
    Map.put(payload, :dispatched_at, DateTime.to_iso8601(DateTime.utc_now()))
  end

  defp compute_signature(payload, secret) do
    mac = :crypto.mac(:hmac, :sha256, secret, Jason.encode!(payload))
    "sha256=" <> Base.encode16(mac, case: :lower)
  end
end
```
