```elixir
defmodule AppWeb.Plugs.VerifyWebhookSignature do
  @moduledoc """
  A Plug that authenticates incoming webhook requests by verifying an
  HMAC signature against the raw request body.

  The raw body is preserved in `conn.assigns.raw_body` for downstream
  handlers that need it. The signature header name, shared secret, and
  hashing algorithm are all configurable per mount via options.

  An optional replay-protection window can be enforced by providing a
  `timestamp_header` option along with a `tolerance_seconds` bound.
  """

  import Plug.Conn

  @behaviour Plug

  @type algorithm :: :sha256 | :sha512
  @type opt ::
          {:secret_key, String.t()}
          | {:signature_header, String.t()}
          | {:algorithm, algorithm()}
          | {:timestamp_header, String.t()}
          | {:tolerance_seconds, pos_integer()}

  @max_body_bytes 2_000_000
  @default_tolerance_seconds 300

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    secret = Keyword.fetch!(opts, :secret_key)
    sig_header = Keyword.get(opts, :signature_header, "x-hub-signature-256")
    algorithm = Keyword.get(opts, :algorithm, :sha256)
    ts_header = Keyword.get(opts, :timestamp_header)
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)

    with {:ok, body, conn} <- read_full_body(conn),
         :ok <- check_timestamp(conn, ts_header, tolerance),
         {:ok, received} <- extract_header(conn, sig_header, :missing_signature),
         :ok <- verify_signature(body, received, secret, algorithm) do
      assign(conn, :raw_body, body)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp read_full_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes) do
      {:ok, body, updated_conn} -> {:ok, body, updated_conn}
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_timestamp(_conn, nil, _tolerance), do: :ok

  defp check_timestamp(conn, header, tolerance) do
    with {:ok, raw_ts} <- extract_header(conn, header, :missing_timestamp),
         {unix, ""} <- Integer.parse(raw_ts),
         {:ok, request_time} <- DateTime.from_unix(unix),
         diff = abs(DateTime.diff(DateTime.utc_now(), request_time, :second)),
         true <- diff <= tolerance do
      :ok
    else
      false -> {:error, :timestamp_outside_tolerance}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp extract_header(conn, header, missing_reason) do
    case get_req_header(conn, header) do
      [value | _] when byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, missing_reason}
    end
  end

  defp verify_signature(body, received, secret, algorithm) do
    expected = compute_mac(body, secret, algorithm)

    if Plug.Crypto.secure_compare(expected, received) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp compute_mac(body, secret, :sha256) do
    mac = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(mac, case: :lower)
  end

  defp compute_mac(body, secret, :sha512) do
    mac = :crypto.mac(:hmac, :sha512, secret, body)
    "sha512=" <> Base.encode16(mac, case: :lower)
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: Atom.to_string(reason)}))
    |> halt()
  end
end
```
