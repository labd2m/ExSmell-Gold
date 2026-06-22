```elixir
defmodule Platform.OAuth2 do
  @moduledoc """
  Context implementing the OAuth2 authorization code flow for acting as
  an authorization server. Handles authorization request validation,
  code generation, token issuance, and refresh token rotation.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Platform.{Repo, OAuth2.AuthCode, OAuth2.AccessToken, OAuth2.Client}
  alias Platform.Jwt

  @type client_id :: String.t()
  @type code :: String.t()
  @type token_response :: %{
          access_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t()
        }

  @code_ttl_seconds 300
  @access_ttl_seconds 3_600
  @refresh_ttl_seconds 2_592_000

  @doc """
  Validates an authorization request and generates an authorization code.
  Returns `{:ok, code}` on success.
  """
  @spec authorize(client_id(), String.t(), String.t(), pos_integer()) ::
          {:ok, code()} | {:error, :invalid_client | :redirect_mismatch}
  def authorize(client_id, redirect_uri, state_param, user_id)
      when is_binary(client_id) and is_binary(redirect_uri) do
    with {:ok, client} <- fetch_client(client_id),
         :ok <- validate_redirect_uri(client, redirect_uri) do
      code = generate_code()
      expires_at = DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)

      attrs = %{
        code: code,
        client_id: client_id,
        redirect_uri: redirect_uri,
        user_id: user_id,
        state: state_param,
        expires_at: expires_at
      }

      case %AuthCode{} |> AuthCode.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:ok, code}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Exchanges an authorization code for an access token and refresh token.
  The code is single-use and consumed on exchange.
  """
  @spec exchange_code(client_id(), String.t(), code()) ::
          {:ok, token_response()} | {:error, :invalid_code | :expired_code | :client_mismatch}
  def exchange_code(client_id, _client_secret, code) when is_binary(code) do
    case Repo.get_by(AuthCode, code: code) do
      nil ->
        {:error, :invalid_code}

      %AuthCode{client_id: ^client_id, expires_at: exp} = auth_code ->
        if DateTime.before?(DateTime.utc_now(), exp) do
          issue_tokens(auth_code)
        else
          Repo.delete(auth_code)
          {:error, :expired_code}
        end

      %AuthCode{} ->
        {:error, :client_mismatch}
    end
  end

  @doc """
  Issues a new access token using a refresh token. Rotates the refresh token.
  """
  @spec refresh(String.t()) ::
          {:ok, token_response()} | {:error, :invalid_refresh_token | :expired}
  def refresh(refresh_token) when is_binary(refresh_token) do
    case Repo.get_by(AccessToken, refresh_token: hash_token(refresh_token)) do
      nil ->
        {:error, :invalid_refresh_token}

      %AccessToken{refresh_expires_at: exp} = token ->
        if DateTime.before?(DateTime.utc_now(), exp) do
          rotate_refresh_token(token)
        else
          {:error, :expired}
        end
    end
  end

  defp issue_tokens(%AuthCode{user_id: user_id, client_id: client_id} = auth_code) do
    secret = Application.fetch_env!(:platform, :jwt_secret)
    access_token = Jwt.issue(%{"sub" => to_string(user_id), "client" => client_id}, secret, @access_ttl_seconds)
    refresh_token = generate_code()

    Multi.new()
    |> Multi.delete(:auth_code, auth_code)
    |> Multi.insert(:access_token, AccessToken.changeset(%AccessToken{}, %{
        user_id: user_id,
        client_id: client_id,
        refresh_token: hash_token(refresh_token),
        refresh_expires_at: DateTime.add(DateTime.utc_now(), @refresh_ttl_seconds, :second)
      }))
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, build_response(access_token, refresh_token)}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp rotate_refresh_token(%AccessToken{user_id: uid, client_id: cid} = old_token) do
    secret = Application.fetch_env!(:platform, :jwt_secret)
    access_token = Jwt.issue(%{"sub" => to_string(uid), "client" => cid}, secret, @access_ttl_seconds)
    new_refresh = generate_code()

    old_token
    |> AccessToken.changeset(%{
        refresh_token: hash_token(new_refresh),
        refresh_expires_at: DateTime.add(DateTime.utc_now(), @refresh_ttl_seconds, :second)
      })
    |> Repo.update()
    |> case do
      {:ok, _} -> {:ok, build_response(access_token, new_refresh)}
      error -> error
    end
  end

  defp build_response(access_token, refresh_token) do
    %{access_token: access_token, token_type: "Bearer", expires_in: @access_ttl_seconds, refresh_token: refresh_token}
  end

  defp fetch_client(client_id) do
    case Repo.get_by(Client, client_id: client_id, active: true) do
      nil -> {:error, :invalid_client}
      client -> {:ok, client}
    end
  end

  defp validate_redirect_uri(%Client{allowed_redirect_uris: uris}, redirect_uri) do
    if redirect_uri in uris, do: :ok, else: {:error, :redirect_mismatch}
  end

  defp generate_code, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
```
