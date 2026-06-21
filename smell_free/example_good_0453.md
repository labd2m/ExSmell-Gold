```elixir
defmodule MyApp.Auth.SSOProvider do
  @moduledoc """
  Handles SAML 2.0 single sign-on authentication for enterprise customers.
  Each organisation can configure its own identity provider; configuration
  is fetched once per request and cached briefly in ETS.

  The authentication flow is split into two public functions:
  `build_request/1` generates the AuthnRequest XML and redirect URL, and
  `handle_response/2` validates the SAML response and returns the
  authenticated user or a structured error.
  """

  alias MyApp.Auth.SamlClient
  alias MyApp.Accounts
  alias MyApp.Tenancy.Organisation

  @cache_ttl_seconds 300

  @type org_id :: String.t()
  @type saml_response :: String.t()

  @type authn_request :: %{
          redirect_url: String.t(),
          relay_state: String.t(),
          request_id: String.t()
        }

  @type sso_error ::
          {:error, :provider_not_configured}
          | {:error, :invalid_response}
          | {:error, :user_not_provisioned}
          | {:error, :signature_invalid}

  @doc """
  Builds an AuthnRequest for the organisation identified by `org_id`.
  Returns the redirect URL and relay state to return to after authentication.
  """
  @spec build_request(org_id()) :: {:ok, authn_request()} | {:error, :provider_not_configured}
  def build_request(org_id) when is_binary(org_id) do
    with {:ok, provider} <- fetch_provider_config(org_id) do
      request_id = "id_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

      case SamlClient.build_authn_request(provider, request_id) do
        {:ok, redirect_url} ->
          {:ok, %{redirect_url: redirect_url, relay_state: org_id, request_id: request_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Validates a SAML response and returns the authenticated user. If the
  user does not yet have a local account and the provider allows
  just-in-time provisioning, a new account is created automatically.
  """
  @spec handle_response(org_id(), saml_response()) ::
          {:ok, Accounts.User.t()} | sso_error()
  def handle_response(org_id, saml_response)
      when is_binary(org_id) and is_binary(saml_response) do
    with {:ok, provider} <- fetch_provider_config(org_id),
         {:ok, assertion} <- SamlClient.parse_and_verify(saml_response, provider),
         :ok <- validate_assertion_expiry(assertion),
         {:ok, user} <- resolve_user(org_id, assertion, provider) do
      {:ok, user}
    end
  end

  @spec fetch_provider_config(org_id()) ::
          {:ok, map()} | {:error, :provider_not_configured}
  defp fetch_provider_config(org_id) do
    cache_key = {:sso_provider, org_id}

    case MyApp.Cache.fetch_or_store(cache_key, fn ->
           load_provider_config(org_id)
         end, @cache_ttl_seconds * 1_000) do
      {:ok, nil} -> {:error, :provider_not_configured}
      {:ok, config} -> {:ok, config}
    end
  end

  @spec load_provider_config(org_id()) :: map() | nil
  defp load_provider_config(org_id) do
    case MyApp.Repo.get_by(Organisation, id: org_id) do
      %{sso_config: config} when is_map(config) -> config
      _ -> nil
    end
  end

  @spec validate_assertion_expiry(map()) :: :ok | {:error, :invalid_response}
  defp validate_assertion_expiry(%{not_on_or_after: expiry}) do
    if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
      :ok
    else
      {:error, :invalid_response}
    end
  end

  defp validate_assertion_expiry(_), do: :ok

  @spec resolve_user(org_id(), map(), map()) ::
          {:ok, Accounts.User.t()} | {:error, :user_not_provisioned}
  defp resolve_user(org_id, assertion, provider) do
    email = Map.fetch!(assertion, :email)

    case Accounts.fetch_by_email(email) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} when provider[:jit_provisioning] == true ->
        provision_user(org_id, assertion)

      {:error, :not_found} ->
        {:error, :user_not_provisioned}
    end
  end

  @spec provision_user(org_id(), map()) ::
          {:ok, Accounts.User.t()} | {:error, :user_not_provisioned}
  defp provision_user(org_id, assertion) do
    params = %{
      email: assertion.email,
      name: Map.get(assertion, :display_name, assertion.email),
      organisation_id: org_id,
      role: :member,
      sso_provisioned: true
    }

    case Accounts.create_sso_user(params) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :user_not_provisioned}
    end
  end
end
```
