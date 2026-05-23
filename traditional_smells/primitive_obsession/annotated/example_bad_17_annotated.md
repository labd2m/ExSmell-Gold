# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `issue_token/3`, `validate_token/2`, `refresh_token/2`, `time_to_expiry/1`
- **Affected Function(s)**: All public functions in `Auth.SessionTokenService`
- **Explanation**: Token expiry is represented as a raw `integer()` Unix timestamp (seconds since epoch) rather than an `%Expiry{issued_at: DateTime.t(), expires_at: DateTime.t(), ttl_seconds: pos_integer()}` struct. The raw integer carries no context about its origin or time zone, all timestamp arithmetic is performed inline with no encapsulation, and callers cannot distinguish an expiry timestamp from any other integer.

## Code

```elixir
defmodule Auth.SessionTokenService do
  @moduledoc """
  Issues, validates, and refreshes session tokens for authenticated users.
  Tokens carry a signed payload with subject, audience, and expiry
  encoded as Unix timestamps. Refresh extends expiry without requiring
  re-authentication for active sessions.
  """

  require Logger

  @default_ttl_seconds 3_600
  @refresh_window_seconds 300
  @max_refresh_count 10
  @signing_secret Application.compile_env(:my_app, :session_secret, "fallback-dev-secret")

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because token expiry is represented as a raw
  # VALIDATION: `integer()` Unix timestamp rather than an `%Expiry{}` struct that
  # VALIDATION: bundles `issued_at`, `expires_at`, and `ttl_seconds` together.
  # VALIDATION: All functions compute, compare, and format this value as a bare
  # VALIDATION: integer, the unit (seconds vs milliseconds) is purely implicit,
  # VALIDATION: and nothing distinguishes a stale-vs-valid token boundary at the
  # VALIDATION: type level.
  @spec issue_token(String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def issue_token(subject, audience, ttl_seconds \\ @default_ttl_seconds)
      when is_binary(subject) and is_binary(audience) and is_integer(ttl_seconds) do
    if ttl_seconds <= 0 do
      {:error, "TTL must be positive, got #{ttl_seconds}"}
    else
      now = System.os_time(:second)
      expires_at = now + ttl_seconds

      payload = %{
        sub: subject,
        aud: audience,
        iat: now,
        exp: expires_at,
        jti: generate_jti()
      }

      token = sign_payload(payload)

      Logger.info(
        "Token issued for #{subject} (aud: #{audience}), " <>
          "expires at #{expires_at} (TTL: #{ttl_seconds}s)"
      )

      {:ok, %{token: token, expires_at: expires_at, ttl_seconds: ttl_seconds}}
    end
  end

  @spec validate_token(String.t(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def validate_token(token, current_time \\ System.os_time(:second)) do
    with {:ok, payload} <- verify_signature(token),
         :ok <- check_expiry(payload.exp, current_time) do
      {:ok, payload}
    end
  end

  @spec refresh_token(String.t(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def refresh_token(token, current_time \\ System.os_time(:second)) do
    with {:ok, payload} <- verify_signature(token) do
      seconds_remaining = payload.exp - current_time
      refresh_count = Map.get(payload, :refresh_count, 0)

      cond do
        seconds_remaining <= 0 ->
          {:error, "Token expired at #{payload.exp}, current time #{current_time}"}

        seconds_remaining > @refresh_window_seconds ->
          {:error,
           "Token still has #{seconds_remaining}s remaining, " <>
             "refresh window is last #{@refresh_window_seconds}s"}

        refresh_count >= @max_refresh_count ->
          {:error, "Token has been refreshed #{refresh_count} times, maximum is #{@max_refresh_count}"}

        true ->
          new_expires_at = current_time + @default_ttl_seconds

          new_payload = payload |> Map.put(:exp, new_expires_at) |> Map.put(:iat, current_time) |> Map.update(:refresh_count, 1, &(&1 + 1))

          new_token = sign_payload(new_payload)

          Logger.info(
            "Token refreshed for #{payload.sub}, new expiry: #{new_expires_at}"
          )

          {:ok, %{token: new_token, expires_at: new_expires_at, ttl_seconds: @default_ttl_seconds}}
      end
    end
  end

  @spec time_to_expiry(integer()) :: integer()
  def time_to_expiry(expires_at) when is_integer(expires_at) do
    max(expires_at - System.os_time(:second), 0)
  end

  @spec expired?(integer()) :: boolean()
  def expired?(expires_at) when is_integer(expires_at) do
    System.os_time(:second) >= expires_at
  end
  # VALIDATION: SMELL END

  defp check_expiry(exp, current_time) do
    if current_time < exp do
      :ok
    else
      {:error, "Token expired at #{exp} (current: #{current_time})"}
    end
  end

  defp sign_payload(payload) do
    serialised = :erlang.term_to_binary(payload)
    hmac = :crypto.mac(:hmac, :sha256, @signing_secret, serialised)
    Base.url_encode64(serialised) <> "." <> Base.url_encode64(hmac)
  end

  defp verify_signature(token) do
    case String.split(token, ".") do
      [encoded_payload, encoded_hmac] ->
        with {:ok, raw_payload} <- Base.url_decode64(encoded_payload),
             {:ok, raw_hmac} <- Base.url_decode64(encoded_hmac) do
          expected_hmac = :crypto.mac(:hmac, :sha256, @signing_secret, raw_payload)

          if :crypto.hash_equals(expected_hmac, raw_hmac) do
            {:ok, :erlang.binary_to_term(raw_payload, [:safe])}
          else
            {:error, "Invalid token signature"}
          end
        end

      _ ->
        {:error, "Malformed token structure"}
    end
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
