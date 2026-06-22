```elixir
defmodule MyApp.Integrations.WebhookSignatureVerifier do
  @moduledoc """
  Verifies HMAC signatures on inbound webhook payloads from multiple
  provider integrations. Each provider uses a slightly different signing
  scheme; the verifier handles the differences through provider-specific
  dispatch clauses while keeping the public API uniform.

  All comparisons use constant-time equality to prevent timing attacks.
  """

  @type provider :: :stripe | :github | :shopify | :twilio
  @type raw_body :: binary()
  @type headers :: %{String.t() => String.t()}

  @doc """
  Verifies the signature on `raw_body` for `provider` using the
  `headers` present in the request. Returns `:ok` or `{:error, reason}`.
  """
  @spec verify(provider(), raw_body(), headers()) :: :ok | {:error, term()}
  def verify(provider, raw_body, headers)
      when provider in [:stripe, :github, :shopify, :twilio] and is_binary(raw_body) do
    secret = fetch_secret(provider)
    do_verify(provider, raw_body, headers, secret)
  end

  @spec do_verify(provider(), raw_body(), headers(), String.t()) :: :ok | {:error, term()}
  defp do_verify(:stripe, body, headers, secret) do
    with sig_header when is_binary(sig_header) <- Map.get(headers, "stripe-signature"),
         {:ok, timestamp, signatures} <- parse_stripe_header(sig_header),
         :ok <- check_stripe_timestamp(timestamp) do
      payload = "#{timestamp}.#{body}"
      expected = compute_hmac(:sha256, secret, payload)

      if Enum.any?(signatures, &secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :signature_mismatch}
    else
      nil -> {:error, :missing_signature_header}
      error -> error
    end
  end

  defp do_verify(:github, body, headers, secret) do
    sig_header = Map.get(headers, "x-hub-signature-256", "")

    case String.split(sig_header, "=", parts: 2) do
      ["sha256", provided_sig] ->
        expected = compute_hmac(:sha256, secret, body)
        if secure_compare(provided_sig, expected), do: :ok, else: {:error, :signature_mismatch}

      _ ->
        {:error, :invalid_signature_format}
    end
  end

  defp do_verify(:shopify, body, headers, secret) do
    provided = Map.get(headers, "x-shopify-hmac-sha256", "")
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
    if secure_compare(provided, expected), do: :ok, else: {:error, :signature_mismatch}
  end

  defp do_verify(:twilio, body, headers, secret) do
    url = Map.get(headers, "x-forwarded-host", "")
    provided = Map.get(headers, "x-twilio-signature", "")
    payload = url <> body
    expected = :crypto.mac(:hmac, :sha1, secret, payload) |> Base.encode64()
    if secure_compare(provided, expected), do: :ok, else: {:error, :signature_mismatch}
  end

  @spec parse_stripe_header(String.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, :invalid_signature_format}
  defp parse_stripe_header(header) do
    parts = header |> String.split(",") |> Enum.map(&String.split(&1, "=", parts: 2))
    timestamp = parts |> Enum.find_value(fn [k, v] -> if k == "t", do: v end)
    sigs = parts |> Enum.flat_map(fn [k, v] -> if k == "v1", do: [v], else: [] end)

    if timestamp && sigs != [], do: {:ok, timestamp, sigs}, else: {:error, :invalid_signature_format}
  end

  @spec check_stripe_timestamp(String.t()) :: :ok | {:error, :timestamp_too_old}
  defp check_stripe_timestamp(ts_str) do
    case Integer.parse(ts_str) do
      {ts, ""} when System.os_time(:second) - ts <= 300 -> :ok
      _ -> {:error, :timestamp_too_old}
    end
  end

  @spec compute_hmac(:sha256 | :sha, String.t(), binary()) :: String.t()
  defp compute_hmac(algo, secret, payload) do
    :crypto.mac(:hmac, algo, secret, payload) |> Base.encode16(case: :lower)
  end

  @spec secure_compare(String.t(), String.t()) :: boolean()
  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false
  defp secure_compare(a, b), do: Plug.Crypto.secure_compare(a, b)

  @spec fetch_secret(provider()) :: String.t()
  defp fetch_secret(provider) do
    Application.fetch_env!(:my_app, :"#{provider}_webhook_secret")
  end
end
```
