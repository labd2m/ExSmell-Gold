```elixir
defmodule Auth do
  @moduledoc """
  Handles user registration, login, and password lifecycle operations.
  """

  alias Auth.{User, PasswordHash, Token, Repo, Mailer}

  @min_password_length 10
  @token_ttl_hours     2


  @doc """
  Creates a new user account. Returns `{:ok, user}` or `{:error, reason}`.
  """
  def register_user(%{"email" => email, "password" => password, "name" => name}) do
    with {:ok, _}    <- validate_email_format(email),
         :ok         <- check_email_available(email),
         :ok         <- validate_password_strength(password),
         {:ok, hash} <- PasswordHash.hash(password) do

      user = %User{
        email:         String.downcase(email),
        name:          String.trim(name),
        password_hash: hash,
        confirmed:     false,
        inserted_at:   DateTime.utc_now()
      }

      case Repo.insert(user) do
        {:ok, saved_user} ->
          Mailer.send_confirmation_email(saved_user)
          {:ok, saved_user}

        {:error, changeset} ->
          {:error, {:db_error, changeset}}
      end
    end
  end


  @doc """
  Resets a user's password after verifying the reset token. Returns `:ok` or
  `{:error, reason}`.
  """
  def reset_password(token_string, %{"password" => new_password}) do
    with {:ok, token}  <- Token.verify(token_string, :password_reset, @token_ttl_hours),
         {:ok, user}   <- Repo.fetch_user(token.user_id),
         false         <- PasswordHash.verify(new_password, user.password_hash) || :same_password,
         :ok           <- validate_password_strength(new_password),
         {:ok, hash}   <- PasswordHash.hash(new_password) do

      case Repo.update_user(user, %{password_hash: hash, force_relogin: true}) do
        {:ok, _updated} ->
          Token.revoke_all(user.id, :password_reset)
          Mailer.send_password_changed_email(user)
          :ok

        {:error, reason} ->
          {:error, {:db_error, reason}}
      end
    else
      :same_password -> {:error, :password_unchanged}
      err            -> err
    end
  end


  defp validate_password_strength(password) do
    cond do
      String.length(password) < @min_password_length ->
        {:error, {:weak_password, :too_short}}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, {:weak_password, :no_uppercase}}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, {:weak_password, :no_digit}}

      not String.match?(password, ~r/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?]/) ->
        {:error, {:weak_password, :no_special_char}}

      true ->
        :ok
    end
  end

  defp validate_email_format(email) do
    if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      {:ok, email}
    else
      {:error, :invalid_email_format}
    end
  end

  defp check_email_available(email) do
    case Repo.find_user_by_email(email) do
      nil -> :ok
      _   -> {:error, :email_already_registered}
    end
  end
end
```
