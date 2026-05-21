```elixir
defmodule TokenValidator do
  @moduledoc """
  Validates JWT-style session tokens for the authentication layer.
  Verifies signature, expiry, and required claims.
  """

  defmodule TokenExpiredError do
    defexception [:message, :expired_at]

    @impl true
    def exception(opts) do
      expired_at = Keyword.fetch!(opts, :expired_at)
      %__MODULE__{
        message: "Token expired at #{expired_at}",
        expired_at: expired_at
      }
    end
  end

  defmodule TokenInvalidError do
    defexception [:message, :reason]

    @impl true
    def exception(opts) do
      reason = Keyword.fetch!(opts, :reason)
      %__MODULE__{
        message: "Token invalid: #{reason}",
        reason: reason
      }
    end
  end

  @signing_secret Application.compile_env(:my_app, :token_secret, "default_secret")
  @token_ttl_seconds 3600

  def verify(token, opts \\ []) do
    required_claims = Keyword.get(opts, :required_claims, [:sub, :iat, :exp])

    unless is_binary(token) and String.length(token) > 0 do
      raise TokenInvalidError, reason: "token must be a non-empty string"
    end

    parts = String.split(token, ".")

    unless length(parts) == 3 do
      raise TokenInvalidError, reason: "malformed token structure"
    end

    [_header_enc, payload_enc, signature_enc] = parts

    claims =
      case Base.url_decode64(payload_enc, padding: false) do
        {:ok, json} ->
          case Jason.decode(json, keys: :atoms) do
            {:ok, decoded} -> decoded
            {:error, _} -> raise TokenInvalidError, reason: "payload is not valid JSON"
          end

        :error ->
          raise TokenInvalidError, reason: "payload is not valid base64url"
      end

    expected_sig = :crypto.mac(:hmac, :sha256, @signing_secret, payload_enc)
    provided_sig = Base.url_decode64(signature_enc, padding: false)

    case provided_sig do
      {:ok, sig} ->
        unless :crypto.hash(:sha256, sig) == :crypto.hash(:sha256, expected_sig) do
          raise TokenInvalidError, reason: "signature mismatch"
        end

      :error ->
        raise TokenInvalidError, reason: "signature is not valid base64url"
    end

    now = System.system_time(:second)
    exp = Map.get(claims, :exp)

    if is_nil(exp) or now > exp do
      raise TokenExpiredError, expired_at: exp
    end

    Enum.each(required_claims, fn claim ->
      unless Map.has_key?(claims, claim) do
        raise TokenInvalidError, reason: "missing required claim: #{claim}"
      end
    end)

    claims
  end
end

defmodule AuthPlug do
  @moduledoc """
  Plug that authenticates requests using Bearer tokens.
  Halts the connection with 401 or 403 when authentication fails.
  """

  import Plug.Conn
  require Logger

  alias TokenValidator
  alias TokenValidator.{TokenExpiredError, TokenInvalidError}

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      # Forced to use try/rescue because TokenValidator.verify/2
      # raises exceptions instead of returning {:ok, _} | {:error, _}.
      try do
        claims = TokenValidator.verify(token, required_claims: [:sub, :exp, :role])

        conn
        |> assign(:current_user_id, claims.sub)
        |> assign(:current_user_role, claims[:role])
      rescue
        e in TokenExpiredError ->
          Logger.info("Rejected expired token: #{e.message}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "token_expired", message: e.message}))
          |> halt()

        e in TokenInvalidError ->
          Logger.warning("Rejected invalid token: #{e.message}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "token_invalid", message: e.message}))
          |> halt()
      end
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "missing_token"}))
        |> halt()
    end
  end
end
```
