```elixir
defmodule Gateway.Plugs.WebhookVerifier do
  @moduledoc """
  Verifies the HMAC-SHA256 signature of incoming webhook requests.

  The raw request body is read once, cached in conn assigns, and then
  signed with the configured secret. The computed digest is compared
  against the value in the configured signature header using a
  timing-safe equality check to prevent timing oracle attacks.
  Requests with a missing or invalid signature are halted with HTTP 401.
  """

  @behaviour Plug

  alias Plug.Conn

  @default_header "x-webhook-signature"

  @impl Plug
  def init(opts) do
    %{
      secret: Keyword.fetch!(opts, :secret),
      header: Keyword.get(opts, :header, @default_header),
      prefix: Keyword.get(opts, :prefix, "sha256=")
    }
  end

  @impl Plug
  def call(%Conn{} = conn, config) do
    with {:ok, body, conn} <- read_body_once(conn),
         {:ok, signature} <- extract_signature(conn, config.header, config.prefix),
         :ok <- verify(body, signature, config.secret) do
      Conn.assign(conn, :raw_webhook_body, body)
    else
      {:error, :missing_signature} -> halt_unauthorized(conn, "Missing webhook signature")
      {:error, :invalid_signature} -> halt_unauthorized(conn, "Invalid webhook signature")
      {:error, :body_read_error} -> halt_unauthorized(conn, "Could not read request body")
    end
  end

  defp read_body_once(%Conn{assigns: %{raw_webhook_body: body}} = conn) do
    {:ok, body, conn}
  end

  defp read_body_once(conn) do
    case Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      _ -> {:error, :body_read_error}
    end
  end

  defp extract_signature(conn, header, prefix) do
    case Conn.get_req_header(conn, header) do
      [value | _] when value != "" ->
        {:ok, String.replace_prefix(value, prefix, "")}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp verify(body, provided_hex, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    if timing_safe_equal?(expected, provided_hex) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp timing_safe_equal?(a, b) when byte_size(a) != byte_size(b), do: false

  defp timing_safe_equal?(a, b) do
    :crypto.hash_equals(a, b)
  rescue
    _ ->
      a_bytes = :binary.bin_to_list(a)
      b_bytes = :binary.bin_to_list(b)

      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
      |> Kernel.==(0)
  end

  defp halt_unauthorized(conn, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(401, body)
    |> Conn.halt()
  end
end
```
