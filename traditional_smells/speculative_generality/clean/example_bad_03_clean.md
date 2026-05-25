```elixir
defmodule Auth.TokenService do
  @moduledoc """
  Issues, validates, and revokes JWT access tokens for the authentication
  subsystem. Tokens are stored with a TTL and invalidated on sign-out.
  """

  alias Auth.{Token, User, TokenStore}
  alias Auth.Repo

  @access_token_ttl  3_600
  @refresh_token_ttl 86_400 * 30
  @issuer            "myapp.internal"

  def issue_token(user, claims \\ %{}, algorithm \\ :hs256) do
    now     = System.system_time(:second)
    expires = now + @access_token_ttl

    payload = Map.merge(claims, %{
      sub:  user.id,
      iss:  @issuer,
      iat:  now,
      exp:  expires,
      role: user.role
    })

    case TokenStore.sign(payload, algorithm) do
      {:ok, token_string} ->
        record = %Token{
          user_id:   user.id,
          token:     token_string,
          algorithm: algorithm,
          expires_at: DateTime.from_unix!(expires),
          revoked:   false
        }

        case Token.changeset(%Token{}, Map.from_struct(record)) |> Repo.insert() do
          {:ok, saved} -> {:ok, saved.token}
          {:error, cs} -> {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def issue_for_user(user_id) do
    user = Repo.get!(User, user_id)
    issue_token(user)
  end

  def issue_refresh_token(user) do
    now     = System.system_time(:second)
    expires = now + @refresh_token_ttl

    payload = %{
      sub:  user.id,
      iss:  @issuer,
      iat:  now,
      exp:  expires,
      type: :refresh
    }

    case TokenStore.sign(payload, :hs256) do
      {:ok, token_string} ->
        {:ok, token_string}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def rotate_token(old_token_string) do
    case validate_token(old_token_string) do
      {:ok, claims} ->
        user = Repo.get!(User, claims["sub"])
        revoke_token(old_token_string)
        issue_token(user)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_token(token_string) do
    case TokenStore.verify(token_string) do
      {:ok, claims} ->
        token_record = Repo.get_by(Token, token: token_string)

        cond do
          is_nil(token_record)    -> {:error, :not_found}
          token_record.revoked    -> {:error, :revoked}
          true                    -> {:ok, claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revoke_token(token_string) do
    case Repo.get_by(Token, token: token_string) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> Token.changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  def revoke_all_for_user(user_id) do
    Token
    |> Repo.all()
    |> Enum.filter(&(&1.user_id == user_id and not &1.revoked))
    |> Enum.each(fn token ->
      token
      |> Token.changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
      |> Repo.update()
    end)
  end

  def list_active_tokens(user_id) do
    now = DateTime.utc_now()

    Token
    |> Repo.all()
    |> Enum.filter(fn t ->
      t.user_id == user_id and
        not t.revoked and
        DateTime.compare(t.expires_at, now) == :gt
    end)
  end
end
```
