# Annotated Example 02

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Auth.TokenValidator.validate_claims/2`, lines accessing `claims[:exp]`, `claims[:sub]`, and `claims[:role]`
- **Affected function(s):** `validate_claims/2`
- **Short explanation:** The function reads three fields from the `claims` map using dynamic bracket access. If any of these keys are absent from the decoded JWT payload (e.g., a non-standard token omits `:role`), `nil` is returned silently. The guards and comparisons that follow then operate on `nil`, making a malformed token appear valid or producing incorrect authorization decisions without any error being raised.

---

```elixir
defmodule Auth.TokenValidator do
  @moduledoc """
  Validates signed JWT tokens for the API gateway.

  Responsibilities:
    - Signature verification (delegated to Auth.Signer)
    - Claims validation (expiry, subject presence, role check)
    - Session lookup to detect revoked tokens
  """

  alias Auth.Signer
  alias Auth.SessionStore

  @allowed_roles ~w(admin editor viewer service_account)
  @clock_skew_seconds 30

  @doc """
  Entry point. Decodes and fully validates the given raw JWT string.
  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  def validate(raw_token, opts \\ []) do
    required_role = Keyword.get(opts, :required_role)

    with {:ok, claims} <- Signer.decode_and_verify(raw_token),
         :ok <- validate_claims(claims, required_role),
         :ok <- check_revocation(claims) do
      {:ok, claims}
    end
  end

  @doc """
  Validates the semantic content of already-decoded JWT claims.
  """
  def validate_claims(claims, required_role \\ nil) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `claims[:exp]`, `claims[:sub]`, and
    # `claims[:role]` use dynamic bracket access on a plain map. A well-formed
    # JWT uses string keys (e.g., `"exp"`), so all three return `nil` for a
    # real token, and the guards below silently pass (nil is not < now, the
    # `is_nil` check on sub triggers, but role comparison compares nil to a
    # string). The developer cannot tell whether a key is absent or genuinely nil.
    exp  = claims[:exp]
    sub  = claims[:sub]
    role = claims[:role]
    # VALIDATION: SMELL END

    now = System.system_time(:second)

    cond do
      is_nil(exp) ->
        {:error, :missing_expiry}

      exp + @clock_skew_seconds < now ->
        {:error, :token_expired}

      is_nil(sub) or sub == "" ->
        {:error, :missing_subject}

      role not in @allowed_roles ->
        {:error, {:invalid_role, role}}

      required_role != nil and role != required_role ->
        {:error, {:insufficient_role, required_role, role}}

      true ->
        :ok
    end
  end

  @doc """
  Checks whether the token's JTI has been revoked.
  """
  def check_revocation(claims) do
    jti = Map.fetch!(claims, "jti")

    case SessionStore.lookup(jti) do
      {:ok, :active}  -> :ok
      {:ok, :revoked} -> {:error, :token_revoked}
      {:error, :not_found} -> {:error, :session_not_found}
    end
  end

  @doc """
  Extracts human-readable identity info from validated claims for audit logs.
  """
  def identity_summary(claims) do
    %{
      subject: Map.get(claims, "sub", "unknown"),
      role: Map.get(claims, "role", "unknown"),
      issued_at: Map.get(claims, "iat"),
      expires_at: Map.get(claims, "exp")
    }
  end
end
```
