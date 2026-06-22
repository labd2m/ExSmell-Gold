```elixir
defmodule OAuth2.TokenClient do
  @moduledoc """
  Issues and refreshes OAuth2 tokens via the client credentials and
  authorization code grant flows.

  All provider-specific parameters (client ID, secret, token URL) are
  supplied per-call through a typed config struct, enabling multi-provider
  usage within the same application without global state.
  """

  alias OAuth2.TokenClient.{Config, TokenResponse, HttpTransport}

  @doc """
  Exchanges a client credentials grant for an access token.
  """
  @spec client_credentials(Config.t(), [String.t()]) ::
          {:ok, TokenResponse.t()} | {:error, String.t()}
  def client_credentials(%Config{} = config, scopes \\ []) when is_list(scopes) do
    params = %{
      grant_type: "client_credentials",
      client_id: config.client_id,
      client_secret: config.client_secret,
      scope: Enum.join(scopes, " ")
    }

    post_token(config, params)
  end

  @doc """
  Exchanges an authorization code for tokens.
  """
  @spec authorization_code(Config.t(), String.t(), String.t()) ::
          {:ok, TokenResponse.t()} | {:error, String.t()}
  def authorization_code(%Config{} = config, code, redirect_uri)
      when is_binary(code) and is_binary(redirect_uri) do
    params = %{
      grant_type: "authorization_code",
      client_id: config.client_id,
      client_secret: config.client_secret,
      code: code,
      redirect_uri: redirect_uri
    }

    post_token(config, params)
  end

  @doc """
  Refreshes an expired access token using a refresh token.
  """
  @spec refresh(Config.t(), String.t()) ::
          {:ok, TokenResponse.t()} | {:error, String.t()}
  def refresh(%Config{} = config, refresh_token) when is_binary(refresh_token) do
    params = %{
      grant_type: "refresh_token",
      client_id: config.client_id,
      client_secret: config.client_secret,
      refresh_token: refresh_token
    }

    post_token(config, params)
  end

  @doc """
  Revokes an active token at the provider's revocation endpoint.
  """
  @spec revoke(Config.t(), String.t(), :access | :refresh) ::
          :ok | {:error, String.t()}
  def revoke(%Config{revocation_url: url} = config, token, token_type)
      when is_binary(token) and is_atom(token_type) and not is_nil(url) do
    hint = Atom.to_string(token_type) <> "_token"

    params = %{
      token: token,
      token_type_hint: hint,
      client_id: config.client_id,
      client_secret: config.client_secret
    }

    case HttpTransport.post(url, params, config.timeout_ms) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke(%Config{revocation_url: nil}, _, _), do: {:error, "provider does not support token revocation"}

  defp post_token(%Config{token_url: url, timeout_ms: timeout}, params) do
    with {:ok, body} <- HttpTransport.post(url, params, timeout),
         {:ok, response} <- TokenResponse.decode(body) do
      {:ok, response}
    end
  end
end

defmodule OAuth2.TokenClient.Config do
  @moduledoc "Per-provider OAuth2 client configuration."

  @enforce_keys [:client_id, :client_secret, :token_url]
  defstruct [:client_id, :client_secret, :token_url, :revocation_url, timeout_ms: 10_000]

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_secret: String.t(),
          token_url: String.t(),
          revocation_url: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(client_id, client_secret, token_url, opts \\ [])
      when is_binary(client_id) and is_binary(client_secret) and is_binary(token_url) do
    %__MODULE__{
      client_id: client_id,
      client_secret: client_secret,
      token_url: token_url,
      revocation_url: Keyword.get(opts, :revocation_url),
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000)
    }
  end
end

defmodule OAuth2.TokenClient.TokenResponse do
  @moduledoc "Typed value object wrapping a decoded OAuth2 token response."

  @enforce_keys [:access_token, :token_type, :expires_in]
  defstruct [:access_token, :token_type, :expires_in, :refresh_token, :scope]

  @type t :: %__MODULE__{
          access_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t() | nil,
          scope: String.t() | nil
        }

  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(%{"access_token" => at, "token_type" => tt, "expires_in" => exp})
      when is_binary(at) and is_binary(tt) and is_integer(exp) do
    {:ok, %__MODULE__{access_token: at, token_type: tt, expires_in: exp}}
  end

  def decode(%{"error" => err, "error_description" => desc}),
    do: {:error, "OAuth2 error #{err}: #{desc}"}

  def decode(%{"error" => err}), do: {:error, "OAuth2 error: #{err}"}
  def decode(_), do: {:error, "unexpected token response format"}
end
```
