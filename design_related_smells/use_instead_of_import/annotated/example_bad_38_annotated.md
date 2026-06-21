# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `SessionManager` module, top-level directive
- **Affected function(s):** `create_session/2`, `refresh/1`, `validate_token/1`
- **Short explanation:** `SessionManager` calls `use TokenHelpers` to obtain JWT-handling and HMAC utilities. The `__using__/1` macro of `TokenHelpers` silently injects an `import` of `HmacSigner` into `SessionManager`, propagating hidden access to `sign/2`, `verify/3`, and `constant_time_compare/2`. A developer reading `SessionManager` cannot know the origin of these functions without inspecting `TokenHelpers` internals. A plain `import TokenHelpers` at the call site would make the dependency surface fully transparent.

---

```elixir
defmodule HmacSigner do
  def sign(payload, secret) when is_binary(payload) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  def verify(payload, signature, secret) do
    expected = sign(payload, secret)
    constant_time_compare(expected, signature)
  end

  def constant_time_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end
  def constant_time_compare(_, _), do: false

  def encode_payload(claims) when is_map(claims) do
    claims
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> Base.url_encode64(padding: false)
  end

  def decode_payload(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         decoded     <- :json.decode(json) do
      {:ok, decoded}
    end
  rescue
    _ -> {:error, :decode_failed}
  end
end

defmodule TokenHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import HmacSigner`
      # VALIDATION: into SessionManager. sign/2, verify/3, constant_time_compare/2,
      # VALIDATION: encode_payload/1, and decode_payload/1 become available in
      # VALIDATION: SessionManager with no visible import statement there.
      # VALIDATION: A maintainer reading SessionManager cannot identify the source of
      # VALIDATION: these security-critical helpers without reading TokenHelpers.
      # VALIDATION: `import TokenHelpers` at the call site would be transparent and
      # VALIDATION: would prevent this silent injection of a dependency.
      import HmacSigner
      # VALIDATION: SMELL END

      @token_separator "."

      def build_token(header, claims, secret) do
        h_enc = encode_payload(header)
        c_enc = encode_payload(claims)
        body  = h_enc <> @token_separator <> c_enc
        sig   = sign(body, secret)
        body  <> @token_separator <> sig
      end

      def parse_token(token) do
        case String.split(token, @token_separator) do
          [header_enc, claims_enc, signature] ->
            with {:ok, header} <- decode_payload(header_enc),
                 {:ok, claims} <- decode_payload(claims_enc) do
              {:ok, %{header: header, claims: claims, signature: signature,
                      raw_body: header_enc <> @token_separator <> claims_enc}}
            end
          _ ->
            {:error, :malformed_token}
        end
      end

      def token_expired?(claims) do
        case Map.get(claims, "exp") do
          nil -> false
          exp -> System.system_time(:second) > exp
        end
      end
    end
  end
end

defmodule SessionManager do
  use TokenHelpers

  @session_ttl      3_600
  @refresh_ttl      86_400 * 30
  @issuer           "my-app"

  def create_session(user, secret) do
    now = System.system_time(:second)

    claims = %{
      sub:  user.id,
      iss:  @issuer,
      iat:  now,
      exp:  now + @session_ttl,
      role: user.role,
      jti:  :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    }

    header = %{alg: "HS256", typ: "JWT"}

    access_token  = build_token(header, claims, secret)
    refresh_claims = Map.merge(claims, %{exp: now + @refresh_ttl, typ: "refresh"})
    refresh_token  = build_token(header, refresh_claims, secret)

    {:ok, %{
      user_id:       user.id,
      access_token:  access_token,
      refresh_token: refresh_token,
      expires_in:    @session_ttl,
      token_type:    "Bearer",
      issued_at:     DateTime.from_unix!(now)
    }}
  end

  def validate_token(token, secret) do
    with {:ok, parsed}   <- parse_token(token),
         false           <- token_expired?(parsed.claims),
         true            <- verify(parsed.raw_body, parsed.signature, secret) do
      {:ok, parsed.claims}
    else
      true  -> {:error, :token_expired}
      false -> {:error, :invalid_signature}
      err   -> err
    end
  end

  def refresh(refresh_token, secret) do
    with {:ok, claims} <- validate_token(refresh_token, secret),
         "refresh"     <- Map.get(claims, "typ", "access") do
      user = %{id: claims["sub"], role: claims["role"]}
      create_session(user, secret)
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def revoke(_token) do
    {:ok, :revoked}
  end

  def session_info(token, secret) do
    case validate_token(token, secret) do
      {:ok, claims} ->
        exp = Map.get(claims, "exp", 0)
        remaining = exp - System.system_time(:second)
        {:ok, %{
          user_id:        claims["sub"],
          role:           claims["role"],
          issued_at:      claims["iat"],
          expires_at:     exp,
          remaining_secs: max(remaining, 0),
          status:         if(remaining > 0, do: :active, else: :expired)
        }}
      err -> err
    end
  end
end
```
