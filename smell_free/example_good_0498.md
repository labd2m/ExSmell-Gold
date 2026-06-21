```elixir
defmodule Accounts.PasswordReset do
  @moduledoc """
  Context for the full password reset flow: token generation, delivery,
  validation, and consumption — all within Ecto transactions.

  Tokens are single-use, time-limited, and stored as hashes. The plaintext
  token is only ever returned once at generation time and is never persisted.
  """

  alias Ecto.Multi
  alias Accounts.{Repo, User, PasswordResetToken}
  alias Accounts.Notifications

  @type email :: String.t()
  @type token :: String.t()
  @type reset_result :: :ok | {:error, :invalid_token | :expired_token | Ecto.Changeset.t()}

  @token_bytes 32
  @token_ttl_hours 2

  @doc """
  Initiates a password reset for the account registered to `email`.
  Generates a token, stores its hash, and sends a reset email.
  Returns `:ok` regardless of whether the email exists to prevent enumeration.
  """
  @spec request(email()) :: :ok
  def request(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> :ok
      user -> generate_and_deliver(user)
    end

    :ok
  end

  @doc """
  Validates `token` and returns the associated user without consuming it.
  Use this to render a pre-filled form before the user submits a new password.
  """
  @spec validate(token()) :: {:ok, User.t()} | {:error, :invalid_token | :expired_token}
  def validate(token) when is_binary(token) do
    token_hash = hash_token(token)

    case Repo.get_by(PasswordResetToken, token_hash: token_hash) do
      nil -> {:error, :invalid_token}
      record -> check_expiry(record)
    end
  end

  @doc """
  Validates `token`, updates the user's password, and invalidates the token
  in a single transaction.
  """
  @spec consume(token(), String.t()) :: reset_result()
  def consume(token, new_password) when is_binary(token) and is_binary(new_password) do
    with {:ok, user} <- validate(token) do
      token_hash = hash_token(token)

      Multi.new()
      |> Multi.update(:user, User.password_changeset(user, %{password: new_password}))
      |> Multi.delete_all(:tokens, fn _ ->
        import Ecto.Query
        from(t in PasswordResetToken, where: t.user_id == ^user.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _} -> :ok
        {:error, :user, changeset, _} -> {:error, changeset}
      end
    end
  end

  defp generate_and_deliver(user) do
    plaintext = generate_token()
    token_hash = hash_token(plaintext)
    expires_at = DateTime.add(DateTime.utc_now(), @token_ttl_hours, :hour)

    attrs = %{user_id: user.id, token_hash: token_hash, expires_at: expires_at}
    changeset = PasswordResetToken.changeset(%PasswordResetToken{}, attrs)

    Multi.new()
    |> Multi.delete_all(:old_tokens, fn _ ->
      import Ecto.Query
      from(t in PasswordResetToken, where: t.user_id == ^user.id)
    end)
    |> Multi.insert(:token, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> Notifications.deliver_password_reset(user, plaintext)
      {:error, _step, _changeset, _} -> :ok
    end
  end

  defp check_expiry(%PasswordResetToken{expires_at: expires_at, user_id: user_id}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      {:ok, Repo.get!(User, user_id)}
    else
      {:error, :expired_token}
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
```
