# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `Auth.register_user/1` and `Auth.reset_password/2`
- **Affected functions:** `register_user/1`, `reset_password/2`
- **Short explanation:** The password-strength checks (minimum length, uppercase, digit, special character) are duplicated across both functions rather than being extracted into a shared private validator.

---

```elixir
defmodule Auth do
  @moduledoc """
  Handles user registration, authentication, and password lifecycle operations.
  """

  alias Auth.{User, Session, Mailer, PasswordHistory}

  @min_password_length 12
  @session_ttl_seconds 86_400

  def register_user(params) do
    with :ok <- validate_registration_params(params),
         :ok <- check_email_available(params.email),
         {:ok, hashed} <- hash_password(params.password),
         {:ok, user} <- create_user(params, hashed) do
      Mailer.send_welcome(user)
      {:ok, user}
    end
  end

  defp validate_registration_params(%{email: email, password: password, name: name}) do
    cond do
      is_nil(name) or String.trim(name) == "" ->
        {:error, :name_required}

      not String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) ->
        {:error, :invalid_email}

      true ->
        # VALIDATION: SMELL START - Duplicated Code
        # VALIDATION: This is a smell because the password strength rules below
        # (length, uppercase, digit, special character) are written out identically
        # inside `validate_new_password/1` used by `reset_password/2`.
        cond do
          String.length(password) < @min_password_length ->
            {:error, {:password_too_short, @min_password_length}}

          not String.match?(password, ~r/[A-Z]/) ->
            {:error, :password_missing_uppercase}

          not String.match?(password, ~r/[0-9]/) ->
            {:error, :password_missing_digit}

          not String.match?(password, ~r/[!@#\$%\^&\*]/) ->
            {:error, :password_missing_special_char}

          true ->
            :ok
        end
        # VALIDATION: SMELL END
    end
  end

  defp validate_registration_params(_), do: {:error, :missing_required_fields}

  def authenticate(email, password) do
    with {:ok, user} <- User.find_by_email(email),
         true <- Bcrypt.verify_pass(password, user.password_hash),
         false <- user.locked do
      session = %Session{
        user_id: user.id,
        token: :crypto.strong_rand_bytes(32) |> Base.encode64(),
        expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)
      }

      Session.persist(session)
      {:ok, session}
    else
      false -> {:error, :account_locked}
      _ -> {:error, :invalid_credentials}
    end
  end

  def reset_password(reset_token, new_password) do
    with {:ok, user} <- User.find_by_reset_token(reset_token),
         :ok <- check_token_expiry(user.reset_token_expires_at),
         :ok <- validate_new_password(new_password),
         false <- PasswordHistory.recently_used?(user.id, new_password),
         {:ok, hashed} <- hash_password(new_password) do
      User.update_password(user, hashed)
      PasswordHistory.record(user.id, hashed)
      User.clear_reset_token(user)
      Mailer.send_password_changed(user)
      :ok
    else
      true -> {:error, :password_recently_used}
      error -> error
    end
  end

  defp validate_new_password(password) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the four password-strength rules here
    # duplicate those in `validate_registration_params/1`. A rule change (e.g.
    # increasing min length) must be applied in both places or behaviour diverges.
    cond do
      String.length(password) < @min_password_length ->
        {:error, {:password_too_short, @min_password_length}}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, :password_missing_uppercase}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, :password_missing_digit}

      not String.match?(password, ~r/[!@#\$%\^&\*]/) ->
        {:error, :password_missing_special_char}

      true ->
        :ok
    end
    # VALIDATION: SMELL END
  end

  defp check_email_available(email) do
    case User.find_by_email(email) do
      {:ok, _} -> {:error, :email_already_taken}
      {:error, :not_found} -> :ok
    end
  end

  defp check_token_expiry(nil), do: {:error, :invalid_token}
  defp check_token_expiry(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp hash_password(password) do
    {:ok, Bcrypt.hash_pwd_salt(password)}
  end

  defp create_user(params, hashed_password) do
    %User{
      id: Ecto.UUID.generate(),
      email: String.downcase(params.email),
      name: String.trim(params.name),
      password_hash: hashed_password,
      role: :member,
      inserted_at: DateTime.utc_now()
    }
    |> Auth.Repo.insert()
  end
end
```
