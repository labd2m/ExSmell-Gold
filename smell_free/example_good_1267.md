```elixir
defmodule Session.Token do
  @moduledoc """
  Generates and verifies short-lived, signed session tokens.
  Tokens encode a user ID and expiry timestamp and are signed with HMAC-SHA256.
  No external dependencies are required beyond the Erlang standard library.
  """

  @separator "."
  @default_ttl_seconds 3_600

  @type claims :: %{user_id: integer(), expires_at: integer()}

  @spec generate(integer(), keyword()) :: {:ok, String.t()} | {:error, :signing_failed}
  def generate(user_id, opts \\ []) when is_integer(user_id) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    expires_at = System.system_time(:second) + ttl

    payload = encode_payload(%{user_id: user_id, expires_at: expires_at})
    secret = fetch_secret()

    case sign(payload, secret) do
      {:ok, signature} -> {:ok, payload <> @separator <> signature}
      :error -> {:error, :signing_failed}
    end
  end

  @spec verify(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    with {:ok, {payload, sig}} <- split_token(token),
         :ok <- verify_signature(payload, sig, fetch_secret()),
         {:ok, claims} <- decode_payload(payload),
         :ok <- check_expiry(claims) do
      {:ok, %{user_id: claims["user_id"], expires_at: claims["expires_at"]}}
    end
  end

  @spec refresh(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def refresh(token, opts \\ []) when is_binary(token) do
    with {:ok, %{user_id: user_id}} <- verify(token) do
      generate(user_id, opts)
    end
  end

  defp encode_payload(claims) do
    claims |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp decode_payload(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :malformed_payload}
    end
  end

  defp sign(payload, secret) do
    try do
      sig =
        :crypto.mac(:hmac, :sha256, secret, payload)
        |> Base.url_encode64(padding: false)

      {:ok, sig}
    rescue
      _ -> :error
    end
  end

  defp verify_signature(payload, provided_sig, secret) do
    {:ok, expected_sig} = sign(payload, secret)

    if Plug.Crypto.secure_compare(provided_sig, expected_sig) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp split_token(token) do
    case String.split(token, @separator, parts: 2) do
      [payload, sig] -> {:ok, {payload, sig}}
      _ -> {:error, :malformed_token}
    end
  end

  defp check_expiry(%{"expires_at" => exp}) when is_integer(exp) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :token_expired}
  end

  defp check_expiry(_), do: {:error, :missing_expiry}

  defp fetch_secret do
    Application.get_env(:session, :secret_key, "dev-insecure-secret")
  end
end
```
