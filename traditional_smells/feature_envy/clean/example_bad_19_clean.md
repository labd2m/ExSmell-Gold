```elixir
defmodule Auth.UserCredential do
  @moduledoc "Represents an authenticated user's credential record."

  defstruct [
    :id,
    :email,
    :role,
    :organization_id,
    :status,
    :mfa_enabled,
    :last_login_at,
    :allowed_scopes,
    :password_changed_at
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      email: "alice@example.com",
      role: :admin,
      organization_id: "ORG-001",
      status: :active,
      mfa_enabled: true,
      last_login_at: ~U[2024-03-10 14:22:00Z],
      allowed_scopes: ["read:invoices", "write:invoices", "read:users"],
      password_changed_at: ~U[2024-01-01 09:00:00Z]
    }
  end

  def active?(%__MODULE__{status: :active}), do: true
  def active?(_), do: false

  def mfa_enabled?(%__MODULE__{mfa_enabled: true}), do: true
  def mfa_enabled?(_), do: false

  def permitted_scopes(%__MODULE__{allowed_scopes: scopes}), do: scopes

  def password_stale?(%__MODULE__{password_changed_at: changed_at}) do
    DateTime.diff(DateTime.utc_now(), changed_at, :day) > 90
  end

  def display_name(%__MODULE__{email: email, role: role}) do
    "#{email} (#{role})"
  end
end

defmodule Auth.TokenIssuer do
  @moduledoc """
  Responsible for issuing signed JWT tokens after a successful authentication
  handshake. Token claims are assembled from the user credential record.
  """

  alias Auth.UserCredential

  @token_ttl_seconds 3600
  @refresh_ttl_seconds 86_400
  @issuer "auth.example.com"

  @doc """
  Issues a signed token pair (access + refresh) for the given credential ID.
  Returns `{:error, reason}` when the credential is inactive or stale.
  """
  def issue(credential_id) do
    credential = UserCredential.get!(credential_id)

    cond do
      not UserCredential.active?(credential) ->
        {:error, :credential_inactive}

      UserCredential.password_stale?(credential) ->
        {:error, :password_rotation_required}

      true ->
        claims = build_token_claims(credential_id)
        access_token  = sign_claims(claims, @token_ttl_seconds)
        refresh_token = sign_claims(%{sub: claims.sub, type: :refresh}, @refresh_ttl_seconds)
        {:ok, %{access_token: access_token, refresh_token: refresh_token, expires_in: @token_ttl_seconds}}
    end
  end

  defp build_token_claims(credential_id) do
    credential = UserCredential.get!(credential_id)

    %{
      sub:    credential.id,
      email:  credential.email,
      role:   credential.role,
      org:    credential.organization_id,
      active: UserCredential.active?(credential),
      mfa:    UserCredential.mfa_enabled?(credential),
      scopes: UserCredential.permitted_scopes(credential),
      iss:    @issuer,
      iat:    DateTime.to_unix(DateTime.utc_now())
    }
  end

  defp sign_claims(claims, ttl) do
    expiry = DateTime.to_unix(DateTime.utc_now()) + ttl
    payload = Map.put(claims, :exp, expiry)
    Base.encode64(:erlang.term_to_binary(payload))
  end
end
```
