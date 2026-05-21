```elixir
defmodule Auth.TokenParser do
  use GenServer

  @moduledoc """
  Parses and validates JWT access tokens issued by the authentication
  service. Used by the API gateway plug on every authenticated request.
  """

  @algorithm "HS256"
  @leeway_seconds 30

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Decodes and validates a JWT `token` string using `secret`.
  Returns `{:ok, claims_map}` or `{:error, reason}`.
  """
  def parse(pid, token, secret) do
    GenServer.call(pid, {:parse, token, secret})
  end

  @doc "Returns `{:ok, claims}` or `{:error, :token_expired}`."
  def verify_expiry(pid, claims) do
    GenServer.call(pid, {:verify_expiry, claims})
  end

  @doc "Returns `{:ok, claims_map}` from a pre-decoded payload map."
  def extract_claims(pid, payload) do
    GenServer.call(pid, {:extract_claims, payload})
  end

  @doc "Checks if `expected_audience` is present in the token's `aud` claim."
  def audience_valid?(pid, claims, expected_audience) do
    GenServer.call(pid, {:audience_valid?, claims, expected_audience})
  end

  @doc "Returns `{:ok, subject}` string or `{:error, :missing_subject}`."
  def subject(pid, claims) do
    GenServer.call(pid, {:subject, claims})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:parse, token, secret}, _from, state) do
    result =
      with {:ok, [header_b64, payload_b64, sig_b64]} <- split_token(token),
           {:ok, header}  <- decode_segment(header_b64),
           {:ok, payload} <- decode_segment(payload_b64),
           :ok            <- verify_algorithm(header),
           :ok            <- verify_signature(header_b64, payload_b64, sig_b64, secret),
           {:ok, claims}  <- extract_standard_claims(payload) do
        {:ok, claims}
      end

    {:reply, result, state}
  end

  def handle_call({:verify_expiry, claims}, _from, state) do
    now = System.system_time(:second)

    result =
      case Map.get(claims, "exp") do
        nil -> {:error, :missing_expiry}
        exp when exp + @leeway_seconds < now -> {:error, :token_expired}
        _ -> {:ok, claims}
      end

    {:reply, result, state}
  end

  def handle_call({:extract_claims, payload}, _from, state) do
    {:reply, extract_standard_claims(payload), state}
  end

  def handle_call({:audience_valid?, claims, expected}, _from, state) do
    aud = Map.get(claims, "aud", [])
    audiences = if is_list(aud), do: aud, else: [aud]
    {:reply, expected in audiences, state}
  end

  def handle_call({:subject, claims}, _from, state) do
    result =
      case Map.get(claims, "sub") do
        nil -> {:error, :missing_subject}
        sub -> {:ok, sub}
      end

    {:reply, result, state}
  end

  ## Private helpers

  defp split_token(token) do
    case String.split(token, ".") do
      [h, p, s] -> {:ok, [h, p, s]}
      _         -> {:error, :malformed_token}
    end
  end

  defp decode_segment(b64) do
    padded = b64 <> String.duplicate("=", rem(4 - rem(byte_size(b64), 4), 4))
    case Base.decode64(padded, padding: false) do
      {:ok, json} -> Jason.decode(json)
      :error      -> {:error, :invalid_base64}
    end
  end

  defp verify_algorithm(%{"alg" => @algorithm}), do: :ok
  defp verify_algorithm(%{"alg" => alg}), do: {:error, {:unsupported_algorithm, alg}}
  defp verify_algorithm(_), do: {:error, :missing_algorithm}

  defp verify_signature(header_b64, payload_b64, sig_b64, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
    provided = Base.url_decode64!(sig_b64, padding: false)
    if :crypto.hash_equals(expected, provided), do: :ok, else: {:error, :invalid_signature}
  end

  defp extract_standard_claims(payload) when is_map(payload), do: {:ok, payload}
  defp extract_standard_claims(_), do: {:error, :invalid_payload}

end
```
