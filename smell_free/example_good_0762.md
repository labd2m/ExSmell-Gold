```elixir
defmodule Accounts.PasswordResetContext do
  @moduledoc """
  Manages the password reset flow: token issuance, validation, and
  password update. Tokens are single-use, time-limited, and stored
  hashed. A successful reset atomically consumes the token and persists
  the new password hash, preventing partial state from reaching the database.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.{PasswordResetToken, User}

  @type user_id :: String.t()
  @type plaintext_token :: String.t()

  @token_bytes 32
  @ttl_minutes 60

  @doc """
  Issues a reset token for the user with `email`. Returns the plaintext
  token to be embedded in the reset URL. Returns `{:error, :not_found}`
  when no account exists for the email.
  """
  @spec request(String.t()) :: {:ok, plaintext_token()} | {:error, :not_found}
  def request(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        {:error, :not_found}

      %User{id: user_id} ->
        Repo.transaction(fn ->
          purge_existing(user_id)
          plaintext = generate_token()
          expires_at = DateTime.add(DateTime.utc_now(), @ttl_minutes * 60, :second)

          attrs = %{
            user_id: user_id,
            token_hash: hash(plaintext),
            expires_at: expires_at
          }

          %PasswordResetToken{}
          |> PasswordResetToken.changeset(attrs)
          |> Repo.insert!()

          plaintext
        end)
    end
  end

  @doc """
  Resets the password for the account associated with `plaintext_token`.
  Returns `{:error, :invalid_token}` for unknown or expired tokens.
  """
  @spec reset(plaintext_token(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_token | :weak_password | Ecto.Changeset.t()}
  def reset(plaintext, new_password)
      when is_binary(plaintext) and is_binary(new_password) do
    token_hash = hash(plaintext)

    case fetch_valid_token(token_hash) do
      nil ->
        {:error, :invalid_token}

      %PasswordResetToken{user_id: user_id} = token ->
        Repo.transaction(fn ->
          Repo.delete!(token)

          user = Repo.get!(User, user_id)

          case user |> User.password_changeset(%{password: new_password}) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  @doc "Returns true when a valid, unexpired reset token exists for `user_id`."
  @spec pending?(user_id()) :: boolean()
  def pending?(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from(t in PasswordResetToken,
        where: t.user_id == ^user_id and t.expires_at > ^now
      )
    )
  end

  defp fetch_valid_token(hash) do
    now = DateTime.utc_now()

    Repo.one(
      from(t in PasswordResetToken,
        where: t.token_hash == ^hash and t.expires_at > ^now
      )
    )
  end

  defp purge_existing(user_id) do
    Repo.delete_all(from(t in PasswordResetToken, where: t.user_id == ^user_id))
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end
end
```
