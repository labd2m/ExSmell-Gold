```elixir
defmodule OAuth.TokenExchange do
  @moduledoc """
  Exchanges an authorization code for an access token and refresh token
  using the OAuth 2.0 authorization code flow. Normalizes responses from
  different providers into a unified `OAuth.TokenSet` struct.
  """

  alias OAuth.{TokenSet, ProviderConfig}

  @type exchange_result :: {:ok, TokenSet.t()} | {:error, atom()}

  @spec exchange_code(ProviderConfig.t(), String.t(), String.t()) :: exchange_result()
  def exchange_code(%ProviderConfig{} = config, code, redirect_uri)
      when is_binary(code) and is_binary(redirect_uri) do
    params = build_params(config, code, redirect_uri)

    with {:ok, response} <- post_token_endpoint(config.token_url, params, config.client_secret),
         {:ok, token_set} <- TokenSet.from_response(response) do
      {:ok, token_set}
    end
  end

  @spec refresh(ProviderConfig.t(), String.t()) :: exchange_result()
  def refresh(%ProviderConfig{} = config, refresh_token) when is_binary(refresh_token) do
    params = [
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: config.client_id
    ]

    with {:ok, response} <- post_token_endpoint(config.token_url, params, config.client_secret),
         {:ok, token_set} <- TokenSet.from_response(response) do
      {:ok, token_set}
    end
  end

  defp build_params(%ProviderConfig{client_id: client_id}, code, redirect_uri) do
    [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      client_id: client_id
    ]
  end

  defp post_token_endpoint(url, params, client_secret) do
    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization", "Basic #{Base.encode64(client_secret)}"}
    ]

    encoded_body = URI.encode_query(params)

    case :hackney.post(url, headers, encoded_body, []) do
      {:ok, 200, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        Jason.decode(body)

      {:ok, status, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        {:error, {:provider_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end
end

defmodule OAuth.TokenSet do
  @moduledoc """
  Normalized representation of an OAuth 2.0 token response.
  """

  @enforce_keys [:access_token, :token_type]
  defstruct [:access_token, :token_type, :refresh_token, :expires_at, :scope]

  @type t :: %__MODULE__{
          access_token: String.t(),
          token_type: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          scope: String.t() | nil
        }

  @spec from_response(map()) :: {:ok, t()} | {:error, :invalid_token_response}
  def from_response(%{"access_token" => access_token, "token_type" => token_type} = body) do
    {:ok,
     %__MODULE__{
       access_token: access_token,
       token_type: token_type,
       refresh_token: Map.get(body, "refresh_token"),
       expires_at: parse_expires_at(Map.get(body, "expires_in")),
       scope: Map.get(body, "scope")
     }}
  end

  def from_response(_), do: {:error, :invalid_token_response}

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defp parse_expires_at(nil), do: nil

  defp parse_expires_at(seconds_in) when is_integer(seconds_in) do
    DateTime.add(DateTime.utc_now(), seconds_in, :second)
  end
end

defmodule OAuth.ProviderConfig do
  @enforce_keys [:provider, :client_id, :client_secret, :token_url, :authorize_url]
  defstruct [:provider, :client_id, :client_secret, :token_url, :authorize_url, :scopes]

  @type t :: %__MODULE__{}

  @spec new(atom(), keyword()) :: {:ok, t()} | {:error, :missing_config}
  def new(provider, opts) when is_atom(provider) do
    required = [:client_id, :client_secret, :token_url, :authorize_url]

    if Enum.all?(required, &Keyword.has_key?(opts, &1)) do
      {:ok,
       %__MODULE__{
         provider: provider,
         client_id: Keyword.fetch!(opts, :client_id),
         client_secret: Keyword.fetch!(opts, :client_secret),
         token_url: Keyword.fetch!(opts, :token_url),
         authorize_url: Keyword.fetch!(opts, :authorize_url),
         scopes: Keyword.get(opts, :scopes, [])
       }}
    else
      {:error, :missing_config}
    end
  end
end
```
