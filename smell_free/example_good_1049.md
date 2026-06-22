```elixir
defmodule Auth.Sessions.TokenIssuer do
  @moduledoc """
  Issues and validates signed session tokens. Token configuration
  (secret, expiry) is provided per-call rather than read from global
  application environment, making this module usable across contexts
  with different token policies.
  """

  alias Auth.Sessions.{TokenClaims, TokenConfig}

  @type issue_result :: {:ok, String.t()} | {:error, :signing_failed}
  @type verify_result :: {:ok, TokenClaims.t()} | {:error, :expired | :invalid | :tampered}

  @doc """
  Issues a signed JWT for `subject_id` using the provided `config`.
  Returns `{:ok, token_string}` or `{:error, :signing_failed}`.
  """
  @spec issue(String.t(), TokenConfig.t()) :: issue_result()
  def issue(subject_id, %TokenConfig{} = config) when is_binary(subject_id) do
    claims = build_claims(subject_id, config)

    case sign(claims, config.secret) do
      {:ok, token} -> {:ok, token}
      {:error, _} -> {:error, :signing_failed}
    end
  end

  @doc """
  Verifies a token string against `config`. Returns the decoded claims on success.
  """
  @spec verify(String.t(), TokenConfig.t()) :: verify_result()
  def verify(token, %TokenConfig{} = config) when is_binary(token) do
    with {:ok, raw_claims} <- decode_and_verify_signature(token, config.secret),
         {:ok, claims} <- parse_claims(raw_claims),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec build_claims(String.t(), TokenConfig.t()) :: map()
  defp build_claims(subject_id, config) do
    now = System.system_time(:second)

    %{
      "sub" => subject_id,
      "iat" => now,
      "exp" => now + config.ttl_seconds,
      "iss" => config.issuer,
      "jti" => generate_jti()
    }
  end

  @spec sign(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp sign(claims, secret) do
    case Jason.encode(claims) do
      {:ok, json} ->
        header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
        payload = Base.url_encode64(json, padding: false)
        unsigned = "#{header}.#{payload}"
        sig = :crypto.mac(:hmac, :sha256, secret, unsigned) |> Base.url_encode64(padding: false)
        {:ok, "#{unsigned}.#{sig}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decode_and_verify_signature(String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid | :tampered}
  defp decode_and_verify_signature(token, secret) do
    case String.split(token, ".") do
      [header, payload, provided_sig] ->
        expected_sig =
          :crypto.mac(:hmac, :sha256, secret, "#{header}.#{payload}")
          |> Base.url_encode64(padding: false)

        if Plug.Crypto.secure_compare(expected_sig, provided_sig) do
          with {:ok, json} <- Base.url_decode64(payload, padding: false),
               {:ok, claims} <- Jason.decode(json) do
            {:ok, claims}
          else
            _ -> {:error, :invalid}
          end
        else
          {:error, :tampered}
        end

      _ ->
        {:error, :invalid}
    end
  end

  @spec parse_claims(map()) :: {:ok, TokenClaims.t()} | {:error, :invalid}
  defp parse_claims(%{"sub" => sub, "exp" => exp, "iat" => iat, "iss" => iss, "jti" => jti})
       when is_binary(sub) and is_integer(exp) do
    {:ok, %TokenClaims{subject_id: sub, expires_at: exp, issued_at: iat, issuer: iss, jti: jti}}
  end

  defp parse_claims(_), do: {:error, :invalid}

  @spec check_expiry(TokenClaims.t()) :: :ok | {:error, :expired}
  defp check_expiry(%TokenClaims{expires_at: exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  @spec generate_jti() :: String.t()
  defp generate_jti do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
