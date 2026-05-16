```elixir
defmodule Auth.IdentityProviderClient do
  @moduledoc """
  OAuth 2.0 client for the company's identity provider (IdP).
  Handles token exchange, refresh, introspection, and revocation flows.
  """

  require Logger

  @token_url "https://idp.internal.company.com/oauth2/token"
  @introspect_url "https://idp.internal.company.com/oauth2/introspect"
  @revoke_url "https://idp.internal.company.com/oauth2/revoke"

  @client_id System.get_env("IDP_CLIENT_ID")
  @client_secret System.get_env("IDP_CLIENT_SECRET")

  def exchange_code(code, redirect_uri, pkce_verifier \\ nil) do
    payload =
      %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: @client_id,
        client_secret: @client_secret
      }
      |> maybe_add_verifier(pkce_verifier)

    case http_post(@token_url, payload) do
      {:ok, raw} -> handle_token_response(raw, :code_exchange)
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  def refresh_token(refresh_token_value) do
    payload = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token_value,
      client_id: @client_id,
      client_secret: @client_secret
    }

    case http_post(@token_url, payload) do
      {:ok, raw} -> handle_token_response(raw, :refresh)
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  def introspect(token) do
    payload = %{token: token, client_id: @client_id, client_secret: @client_secret}

    case http_post(@introspect_url, payload) do
      {:ok, %{status: 200, body: %{"active" => true, "sub" => sub, "exp" => exp}}} ->
        {:ok, %{active: true, subject: sub, expires_at: exp}}

      {:ok, %{status: 200, body: %{"active" => false}}} ->
        {:ok, %{active: false}}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def revoke(token) do
    payload = %{token: token, client_id: @client_id, client_secret: @client_secret}

    case http_post(@revoke_url, payload) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp handle_token_response(response, flow) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "access_token" => at,
            "refresh_token" => rt,
            "expires_in" => exp,
            "scope" => scope,
            "token_type" => type
          } ->
            {:ok,
             %{
               access_token: at,
               refresh_token: rt,
               expires_in: exp,
               scope: String.split(scope, " "),
               token_type: String.downcase(type),
               flow: flow
             }}

          %{"access_token" => at, "expires_in" => exp, "scope" => scope} ->
            Logger.warning("No refresh_token issued for flow=#{flow}")
            {:ok,
             %{
               access_token: at,
               refresh_token: nil,
               expires_in: exp,
               scope: String.split(scope, " "),
               token_type: "bearer",
               flow: flow
             }}

          %{"access_token" => at, "expires_in" => exp} ->
            {:ok,
             %{
               access_token: at,
               refresh_token: nil,
               expires_in: exp,
               scope: [],
               token_type: "bearer",
               flow: flow
             }}

          _ ->
            {:error, :malformed_token_response}
        end

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_grant", "error_description" => desc} ->
            {:error, {:invalid_grant, desc}}

          %{"error" => "invalid_grant"} ->
            {:error, :invalid_grant}

          %{"error" => "invalid_client"} ->
            {:error, :invalid_client}

          %{"error" => "invalid_scope", "error_description" => desc} ->
            {:error, {:invalid_scope, desc}}

          %{"error" => "invalid_scope"} ->
            {:error, :invalid_scope}

          %{"error" => "unsupported_grant_type"} ->
            {:error, :unsupported_grant_type}

          %{"error" => code, "error_description" => desc} ->
            {:error, {:oauth_error, code, desc}}

          %{"error" => code} ->
            {:error, {:oauth_error, code, nil}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401, body: %{"error" => "invalid_client"}} ->
        Logger.error("IdP rejected client credentials for flow=#{flow}")
        {:error, :invalid_client_credentials}

      %{status: 401} ->
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "mfa_required", "mfa_token" => mfa_token}} ->
        {:error, {:mfa_required, mfa_token}}

      %{status: 403, body: %{"error" => "account_locked", "unlock_url" => url}} ->
        {:error, {:account_locked, url}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 429, body: %{"retry_after" => seconds}} ->
        {:error, {:rate_limited, seconds}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"trace_id" => tid}} ->
        Logger.error("IdP 500 error trace_id=#{tid} flow=#{flow}")
        {:error, {:server_error, tid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status} ->
        {:error, {:unexpected_status, status}}
    end
  end

  defp maybe_add_verifier(payload, nil), do: payload
  defp maybe_add_verifier(payload, verifier), do: Map.put(payload, :code_verifier, verifier)

  defp http_post(_url, _payload), do: {:error, :not_implemented}
end
```
