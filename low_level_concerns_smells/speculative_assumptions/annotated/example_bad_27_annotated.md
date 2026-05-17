# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Auth.TokenParser.extract_claims/1`, around the Base64 decode and split logic
- **Affected function(s):** `extract_claims/1`
- **Short explanation:** The function splits a JWT-like token by "." and accesses the payload segment positionally with `Enum.at/1`, then decodes it without verifying the token has the expected three-part structure. If a token is malformed, truncated, or uses a different format, `Enum.at` returns `nil` silently and subsequent decoding attempts return wrong or empty data. The function always returns *something*, masking the structural mismatch and creating a false sense of correctness.

---

```elixir
defmodule Auth.TokenParser do
  @moduledoc """
  Parses and validates signed access tokens used by the authentication service.
  Tokens are expected to be in the format: <header>.<payload>.<signature>
  where each segment is Base64URL-encoded JSON.
  """

  require Logger

  @token_separator "."
  @required_claims ~w(sub iat exp roles)

  def parse(raw_token) when is_binary(raw_token) do
    raw_token
    |> String.trim()
    |> extract_claims()
    |> validate_claims()
  end

  def parse(_), do: {:error, :invalid_token_format}

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits the token by "." and uses
  # VALIDATION: Enum.at/2 with a hardcoded index to grab the payload segment.
  # VALIDATION: If the token has fewer than 3 parts (e.g., a truncated or totally
  # VALIDATION: different token format), Enum.at returns nil silently. The subsequent
  # VALIDATION: Base64 decode then receives nil and the entire claim map becomes
  # VALIDATION: empty/incorrect, but the function never crashes — it returns a
  # VALIDATION: plausible-looking result that is actually wrong, bypassing the
  # VALIDATION: supervisor's ability to detect failures through crashes.
  defp extract_claims(token) do
    parts = String.split(token, @token_separator)

    payload_segment = Enum.at(parts, 1)

    decoded =
      case Base.url_decode64(payload_segment || "", padding: false) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, map} -> map
            _          -> %{}
          end

        _ ->
          %{}
      end

    decoded
  end
  # VALIDATION: SMELL END

  defp validate_claims(claims) when map_size(claims) == 0 do
    {:error, :empty_claims}
  end

  defp validate_claims(claims) do
    missing = Enum.reject(@required_claims, &Map.has_key?(claims, &1))

    if missing == [] do
      with :ok <- validate_expiry(claims),
           :ok <- validate_subject(claims) do
        {:ok, build_identity(claims)}
      end
    else
      {:error, {:missing_claims, missing}}
    end
  end

  defp validate_expiry(%{"exp" => exp}) do
    now = System.system_time(:second)

    if exp > now do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp validate_expiry(_), do: {:error, :missing_expiry}

  defp validate_subject(%{"sub" => sub}) when is_binary(sub) and byte_size(sub) > 0, do: :ok
  defp validate_subject(_), do: {:error, :invalid_subject}

  defp build_identity(claims) do
    %{
      user_id:    Map.get(claims, "sub"),
      issued_at:  Map.get(claims, "iat"),
      expires_at: Map.get(claims, "exp"),
      roles:      Map.get(claims, "roles", []),
      email:      Map.get(claims, "email"),
      tenant_id:  Map.get(claims, "tid")
    }
  end

  def has_role?(identity, role) do
    role in Map.get(identity, :roles, [])
  end

  def expired?(identity) do
    now = System.system_time(:second)
    Map.get(identity, :expires_at, 0) <= now
  end

  def format_identity(%{user_id: uid, roles: roles, email: email}) do
    "User #{uid} <#{email}> roles=#{Enum.join(roles, ",")}"
  end

  def format_identity(_), do: "Unknown identity"
end
```
