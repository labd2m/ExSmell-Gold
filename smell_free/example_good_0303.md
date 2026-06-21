```elixir
defmodule Integration.WebhookVerifier do
  @moduledoc """
  Verifies inbound webhook signatures from third-party providers. Each
  provider is registered with its own signature scheme. Verification is
  timing-safe to prevent timing-oracle attacks. Unrecognised providers
  return a typed error rather than a boolean so callers can distinguish
  between a bad signature and an unknown provider.
  """

  @type provider :: :stripe | :github | :shopify | :twilio
  @type headers :: %{String.t() => String.t()}
  @type body :: binary()
  @type verify_result :: :ok | {:error, :invalid_signature | :unknown_provider | :missing_header}

  @doc """
  Verifies that `body` was signed by `provider` given its `headers`.
  Returns `:ok` when verification passes or a typed error otherwise.
  """
  @spec verify(provider(), headers(), body()) :: verify_result()
  def verify(provider, headers, body)
      when is_atom(provider) and is_map(headers) and is_binary(body) do
    case provider do
      :stripe -> verify_stripe(headers, body)
      :github -> verify_github(headers, body)
      :shopify -> verify_shopify(headers, body)
      :twilio -> verify_twilio(headers, body)
      _ -> {:error, :unknown_provider}
    end
  end

  defp verify_stripe(headers, body) do
    with {:ok, sig_header} <- get_header(headers, "stripe-signature"),
         {:ok, secret} <- fetch_secret(:stripe),
         {:ok, timestamp, signatures} <- parse_stripe_header(sig_header),
         payload = "#{timestamp}.#{body}",
         {:ok, expected} <- hmac_sha256(secret, payload) do
      if Enum.any?(signatures, &secure_compare(&1, expected)), do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  defp verify_github(headers, body) do
    with {:ok, sig_header} <- get_header(headers, "x-hub-signature-256"),
         {:ok, secret} <- fetch_secret(:github),
         {:ok, expected} <- hmac_sha256(secret, body),
         expected_header = "sha256=#{expected}" do
      if secure_compare(sig_header, expected_header), do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  defp verify_shopify(headers, body) do
    with {:ok, sig_header} <- get_header(headers, "x-shopify-hmac-sha256"),
         {:ok, secret} <- fetch_secret(:shopify),
         {:ok, expected} <- hmac_sha256_base64(secret, body) do
      if secure_compare(sig_header, expected), do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  defp verify_twilio(headers, body) do
    with {:ok, sig_header} <- get_header(headers, "x-twilio-signature"),
         {:ok, secret} <- fetch_secret(:twilio),
         {:ok, expected} <- hmac_sha1_base64(secret, body) do
      if secure_compare(sig_header, expected), do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  defp get_header(headers, key) do
    case Map.get(headers, key) do
      nil -> {:error, :missing_header}
      value -> {:ok, value}
    end
  end

  defp fetch_secret(provider) do
    key = :"webhook_secret_#{provider}"
    case Application.get_env(:my_app, key) do
      nil -> {:error, :missing_header}
      secret -> {:ok, secret}
    end
  end

  defp hmac_sha256(secret, payload) do
    digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    {:ok, digest}
  end

  defp hmac_sha256_base64(secret, payload) do
    digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()
    {:ok, digest}
  end

  defp hmac_sha1_base64(secret, payload) do
    digest = :crypto.mac(:hmac, :sha, secret, payload) |> Base.encode64()
    {:ok, digest}
  end

  defp parse_stripe_header(header) do
    parts = String.split(header, ",")
    timestamp = parts |> Enum.find("", &String.starts_with?(&1, "t=")) |> String.trim_leading("t=")
    sigs = parts |> Enum.filter(&String.starts_with?(&1, "v1=")) |> Enum.map(&String.trim_leading(&1, "v1="))
    if timestamp == "", do: {:error, :invalid_signature}, else: {:ok, timestamp, sigs}
  end

  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false
  defp secure_compare(a, b), do: :crypto.hash_equals(a, b)
end
```
