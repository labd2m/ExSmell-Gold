```elixir
defmodule MyApp.Plug.HmacAuth do
  @moduledoc """
  A Plug that authenticates inbound webhook requests using HMAC-SHA256
  signatures. The expected signature is read from the `X-Hub-Signature-256`
  header, computed against the raw request body, and compared in
  constant time to prevent timing attacks.

  ## Usage

      plug MyApp.Plug.HmacAuth, secret_key: "my_webhook_secret"

  The plug halts the connection and returns `403` when the signature is
  absent, malformed, or does not match the computed value.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @signature_header "x-hub-signature-256"
  @signature_prefix "sha256="
  @prefix_length byte_size(@signature_prefix)

  @type opts :: [secret_key: binary()]

  @impl Plug
  @spec init(opts()) :: binary()
  def init(opts) do
    Keyword.fetch!(opts, :secret_key)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def call(conn, secret_key) do
    with {:ok, raw_body} <- read_cached_body(conn),
         {:ok, received_sig} <- extract_signature(conn),
         :ok <- verify_signature(raw_body, received_sig, secret_key) do
      conn
    else
      {:error, reason} ->
        log_failure(conn, reason)
        reject(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp read_cached_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, :body_not_cached}
      body when is_binary(body) -> {:ok, body}
    end
  end

  defp extract_signature(conn) do
    case get_req_header(conn, @signature_header) do
      [header_value | _] -> parse_signature(header_value)
      [] -> {:error, :signature_header_missing}
    end
  end

  defp parse_signature(@signature_prefix <> hex_sig) when byte_size(hex_sig) == 64 do
    case Base.decode16(hex_sig, case: :lower) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, :signature_malformed}
    end
  end

  defp parse_signature(raw) when byte_size(raw) == @prefix_length + 64 do
    {:error, :signature_malformed}
  end

  defp parse_signature(_), do: {:error, :signature_malformed}

  defp verify_signature(body, received_sig, secret_key) do
    expected_sig = :crypto.mac(:hmac, :sha256, secret_key, body)

    if Plug.Crypto.secure_compare(expected_sig, received_sig) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  defp reject(conn) do
    conn
    |> send_resp(:forbidden, "Forbidden")
    |> halt()
  end

  defp log_failure(conn, reason) do
    Logger.warning("HmacAuth rejected request",
      reason: reason,
      remote_ip: format_ip(conn.remote_ip),
      path: conn.request_path
    )
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({_, _, _, _, _, _, _, _} = v6), do: :inet.ntoa(v6) |> to_string()
  defp format_ip(_), do: "unknown"
end

defmodule MyApp.Plug.CacheRawBody do
  @moduledoc """
  Must be placed before `HmacAuth` in the pipeline. Reads and caches
  the raw request body into `conn.assigns[:raw_body]` so that it remains
  accessible after Plug has consumed the body stream.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    Plug.Conn.assign(conn, :raw_body, body)
  end
end
```
