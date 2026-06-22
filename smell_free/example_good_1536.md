```elixir
defmodule Analytics.EventIngestionPlug do
  @moduledoc """
  Plug middleware for capturing and buffering analytics events from HTTP requests.

  Extracts structured event data from the connection, validates required fields,
  and enqueues accepted events to the async ingestion buffer. Rejected events
  receive an immediate 422 response with a descriptive error payload.
  """

  import Plug.Conn

  alias Analytics.IngestionBuffer
  alias Analytics.EventValidator

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, raw_event} <- decode_json(body),
         {:ok, event} <- EventValidator.validate(raw_event),
         :ok <- IngestionBuffer.enqueue(event) do
      send_accepted(conn)
    else
      {:error, :invalid_json} ->
        send_error(conn, 400, "Invalid JSON payload")

      {:error, :validation_failed, reasons} ->
        send_error(conn, 422, %{errors: reasons})

      {:error, :buffer_full} ->
        send_error(conn, 503, "Ingestion buffer is full, retry later")
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp send_accepted(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, Jason.encode!(%{status: "accepted"}))
    |> halt()
  end

  defp send_error(conn, status, message) when is_binary(message) do
    send_error(conn, status, %{error: message})
  end

  defp send_error(conn, status, payload) when is_map(payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end
end

defmodule Analytics.EventValidator do
  @moduledoc """
  Validates raw inbound analytics event maps against required field contracts.
  """

  @required_fields ~w(event_name user_id occurred_at)

  @type validation_result ::
          {:ok, map()} | {:error, :validation_failed, [String.t()]}

  @doc """
  Validates a raw event map against the required field schema.

  Returns `{:ok, event}` when valid or `{:error, :validation_failed, reasons}`
  with a list of human-readable rejection messages.
  """
  @spec validate(map()) :: validation_result()
  def validate(raw_event) when is_map(raw_event) do
    errors =
      []
      |> check_required_fields(raw_event)
      |> check_event_name_format(raw_event)
      |> check_timestamp_format(raw_event)

    case errors do
      [] -> {:ok, raw_event}
      reasons -> {:error, :validation_failed, reasons}
    end
  end

  defp check_required_fields(errors, event) do
    missing =
      @required_fields
      |> Enum.filter(fn field -> not (Map.has_key?(event, field) and event[field] != nil) end)
      |> Enum.map(fn field -> "#{field} is required" end)

    errors ++ missing
  end

  defp check_event_name_format(errors, %{"event_name" => name}) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/, name) do
      errors
    else
      errors ++ ["event_name must be snake_case, optionally namespaced with dots"]
    end
  end

  defp check_event_name_format(errors, _), do: errors

  defp check_timestamp_format(errors, %{"occurred_at" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, _, _} -> errors
      _ -> errors ++ ["occurred_at must be a valid ISO 8601 datetime"]
    end
  end

  defp check_timestamp_format(errors, _), do: errors
end
```
