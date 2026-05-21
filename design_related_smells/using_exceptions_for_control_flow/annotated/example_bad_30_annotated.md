# Annotated Example 30

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `TokenValidator.verify/2` (library) and `ApiPlug.call/2` (client)
- **Affected function(s):** `TokenValidator.verify/2`, `ApiPlug.call/2`
- **Short explanation:** `TokenValidator.verify/2` raises exceptions for expired tokens, invalid signatures, and unsupported algorithms — all of which are expected during normal API request authentication. Because no tuple-returning alternative is provided, the `ApiPlug` middleware is forced to use `try...rescue` to decide whether to pass a request through or return a 401, making exception handling the only path for routine auth decisions.

```elixir
defmodule TokenValidator do
  @moduledoc """
  Validates signed JWT tokens used for API authentication.
  Checks signature, expiry, audience, and algorithm constraints.
  """

  defmodule TokenExpiredError do
    defexception [:message, :expired_at]
  end

  defmodule InvalidSignatureError do
    defexception [:message]
  end

  defmodule UnsupportedAlgorithmError do
    defexception [:message, :algorithm]
  end

  defmodule MalformedTokenError do
    defexception [:message]
  end

  defmodule AudienceMismatchError do
    defexception [:message, :expected, :got]
  end

  @supported_algorithms ~w(HS256 RS256)
  @secret "super-secret-signing-key-do-not-share"

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because expired and invalid tokens arrive with
  # every batch of API requests in production — they are not exceptional events.
  # A plug or middleware that must authenticate every request is forced to use
  # try...rescue as the primary branching mechanism, which is poor design.
  def verify(token, expected_audience) when not is_binary(token) or token == "" do
    raise MalformedTokenError, message: "Token must be a non-empty string"
  end

  def verify(token, expected_audience) do
    {header, claims, signature} = decode_parts(token)

    algorithm = Map.get(header, "alg", "none")

    unless algorithm in @supported_algorithms do
      raise UnsupportedAlgorithmError,
        message: "Algorithm '#{algorithm}' is not supported; use one of #{Enum.join(@supported_algorithms, ", ")}",
        algorithm: algorithm
    end

    unless valid_signature?(token, signature) do
      raise InvalidSignatureError, message: "Token signature verification failed"
    end

    exp = Map.get(claims, "exp")

    if is_integer(exp) and exp < System.system_time(:second) do
      expired_at = DateTime.from_unix!(exp)

      raise TokenExpiredError,
        message: "Token expired at #{expired_at}",
        expired_at: expired_at
    end

    aud = Map.get(claims, "aud")

    if aud != expected_audience do
      raise AudienceMismatchError,
        message: "Token audience '#{aud}' does not match expected '#{expected_audience}'",
        expected: expected_audience,
        got: aud
    end

    %{
      subject: Map.get(claims, "sub"),
      roles: Map.get(claims, "roles", []),
      audience: aud,
      issued_at: claims |> Map.get("iat") |> DateTime.from_unix!(),
      expires_at: exp && DateTime.from_unix!(exp)
    }
  end
  # VALIDATION: SMELL END

  defp decode_parts(token) do
    parts = String.split(token, ".")

    case parts do
      [h, p, s] ->
        header = h |> Base.decode64!(padding: false) |> Jason.decode!()
        claims = p |> Base.decode64!(padding: false) |> Jason.decode!()
        {header, claims, s}

      _ ->
        raise MalformedTokenError, message: "Token does not have three dot-separated parts"
    end
  rescue
    _ -> raise MalformedTokenError, message: "Token could not be decoded"
  end

  defp valid_signature?(token, _sig) do
    not String.ends_with?(token, "badsig")
  end
end

defmodule ApiPlug do
  @moduledoc """
  Rack-style plug that authenticates inbound API requests via Bearer tokens.
  Attaches the verified identity to the connection if valid.
  """

  require Logger

  @audience "api.myapp.com"

  def call(conn, _opts) do
    token = get_bearer_token(conn)

    if is_nil(token) do
      send_error(conn, 401, "missing_token", "Authorization header is required")
    else
      authenticate(conn, token)
    end
  end

  defp authenticate(conn, token) do
    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because every single API request runs through
    # this code path. Expired tokens and signature failures are constant,
    # foreseeable occurrences that the plug developer should be able to handle
    # with a simple case statement — but TokenValidator forces try...rescue.
    try do
      identity = TokenValidator.verify(token, @audience)
      Logger.debug("Authenticated subject: #{identity.subject}")
      assign(conn, :current_identity, identity)
    rescue
      e in TokenValidator.TokenExpiredError ->
        Logger.debug("Rejected expired token, expired at #{e.expired_at}")
        send_error(conn, 401, "token_expired", "Your session has expired; please log in again")

      _e in TokenValidator.InvalidSignatureError ->
        Logger.warning("Rejected token with invalid signature")
        send_error(conn, 401, "invalid_signature", "Token signature is invalid")

      e in TokenValidator.UnsupportedAlgorithmError ->
        Logger.warning("Unsupported JWT algorithm: #{e.algorithm}")
        send_error(conn, 400, "unsupported_algorithm", e.message)

      e in TokenValidator.AudienceMismatchError ->
        Logger.warning("Audience mismatch: expected #{e.expected}, got #{e.got}")
        send_error(conn, 401, "audience_mismatch", "Token is not valid for this service")

      _e in TokenValidator.MalformedTokenError ->
        send_error(conn, 400, "malformed_token", "Token format is invalid")
    end
    # VALIDATION: SMELL END
  end

  defp get_bearer_token(conn) do
    case Map.get(conn.headers, "authorization") do
      "Bearer " <> token -> token
      _ -> nil
    end
  end

  defp send_error(conn, status, code, message) do
    Map.merge(conn, %{status: status, body: %{error: code, message: message}, halted: true})
  end

  defp assign(conn, key, value) do
    Map.update(conn, :assigns, %{key => value}, &Map.put(&1, key, value))
  end
end
```
