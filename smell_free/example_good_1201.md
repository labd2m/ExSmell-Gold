```elixir
defmodule Web.Plugs.WebhookVerifier do
  @moduledoc """
  A Plug that verifies the HMAC-SHA256 signature of inbound webhook
  requests before the body is consumed by downstream handlers.
  The raw request body is cached on the connection so it remains
  readable after verification.
  """

  import Plug.Conn

  @behaviour Plug

  @signature_header "x-webhook-signature"
  @timestamp_header "x-webhook-timestamp"
  @max_clock_skew_seconds 300

  @type opts :: [secret_key: String.t(), tolerance_seconds: pos_integer()]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    secret = Keyword.fetch!(opts, :secret_key)
    tolerance = Keyword.get(opts, :tolerance_seconds, @max_clock_skew_seconds)

    with {:ok, raw_body} <- read_raw_body(conn),
         {:ok, signature} <- extract_header(conn, @signature_header),
         {:ok, timestamp} <- extract_header(conn, @timestamp_header),
         :ok <- verify_timestamp(timestamp, tolerance),
         :ok <- verify_signature(raw_body, timestamp, signature, secret) do
      assign(conn, :raw_webhook_body, raw_body)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  @spec read_raw_body(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :body_read_error}
  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> {:ok, body}
      _ -> {:error, :body_read_error}
    end
  end

  @spec extract_header(Plug.Conn.t(), String.t()) :: {:ok, String.t()} | {:error, :missing_header}
  defp extract_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> {:ok, value}
      _ -> {:error, :missing_header}
    end
  end

  @spec verify_timestamp(String.t(), pos_integer()) :: :ok | {:error, :timestamp_expired}
  defp verify_timestamp(timestamp_str, tolerance) do
    case Integer.parse(timestamp_str) do
      {ts, ""} ->
        age = abs(System.os_time(:second) - ts)
        if age <= tolerance, do: :ok, else: {:error, :timestamp_expired}

      _ ->
        {:error, :timestamp_expired}
    end
  end

  @spec verify_signature(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_signature}
  defp verify_signature(body, timestamp, provided_signature, secret) do
    signed_payload = "#{timestamp}.#{body}"

    expected =
      :crypto.mac(:hmac, :sha256, secret, signed_payload)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, provided_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @spec reject(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  defp reject(conn, reason) do
    body = Jason.encode!(%{error: rejection_message(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  @spec rejection_message(atom()) :: String.t()
  defp rejection_message(:missing_header), do: "Required signature headers are missing"
  defp rejection_message(:timestamp_expired), do: "Request timestamp is outside tolerance window"
  defp rejection_message(:invalid_signature), do: "Signature verification failed"
  defp rejection_message(:body_read_error), do: "Unable to read request body"
  defp rejection_message(_), do: "Webhook verification failed"
end
```
