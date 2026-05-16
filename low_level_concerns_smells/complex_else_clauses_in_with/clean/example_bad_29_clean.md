```elixir
defmodule Auth.TokenPipeline do
  @moduledoc """
  Validates and resolves inbound API requests through a multi-step
  authentication and authorization pipeline.
  """

  alias Auth.{TokenStore, SessionStore, UserRepo, PolicyEngine, AuditLog}
  require Logger

  @token_header "x-api-token"
  @max_token_age_seconds 3_600

  @doc """
  Authenticates an incoming Plug connection.

  Returns `{:ok, user, session}` on success, or a tagged error suitable
  for rendering an HTTP response.
  """
  @spec authenticate_request(Plug.Conn.t()) ::
          {:ok, map(), map()}
          | {:error, :missing_token}
          | {:error, :malformed_token}
          | {:error, :token_expired}
          | {:error, :user_not_found}
          | {:error, :unauthorized}
  def authenticate_request(conn) do
    with {:ok, raw_token}  <- extract_token(conn),
         {:ok, claims}     <- decode_token(raw_token),
         {:ok, _session}   <- validate_session(claims),
         {:ok, user}       <- UserRepo.fetch(claims["sub"]),
         :ok               <- PolicyEngine.authorize(user, conn.request_path) do
      session = SessionStore.get(claims["jti"])
      AuditLog.record(:auth_success, user.id, conn.remote_ip)
      {:ok, user, session}
    else
      :missing ->
        {:error, :missing_token}

      {:error, :decode_failed} ->
        Logger.debug("Token decode failure")
        {:error, :malformed_token}

      {:error, :expired, expired_at} ->
        Logger.info("Expired token, expired_at=#{expired_at}")
        {:error, :token_expired}

      {:error, :not_found} ->
        Logger.warn("User referenced in token no longer exists")
        {:error, :user_not_found}

      {:error, :forbidden, resource} ->
        Logger.warn("Authorization denied for resource: #{resource}")
        {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_token(conn) do
    case Plug.Conn.get_req_header(conn, @token_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> :missing
    end
  end

  defp decode_token(raw) do
    case TokenStore.decode(raw) do
      {:ok, %{"sub" => _, "jti" => _, "iat" => _} = claims} -> {:ok, claims}
      {:ok, _incomplete}                                      -> {:error, :decode_failed}
      {:error, _reason}                                       -> {:error, :decode_failed}
    end
  end

  defp validate_session(%{"jti" => jti, "iat" => iat}) do
    age = System.system_time(:second) - iat

    cond do
      age > @max_token_age_seconds ->
        {:error, :expired, DateTime.from_unix!(iat)}

      not SessionStore.active?(jti) ->
        {:error, :expired, DateTime.from_unix!(iat)}

      true ->
        {:ok, SessionStore.get(jti)}
    end
  end
end
```
