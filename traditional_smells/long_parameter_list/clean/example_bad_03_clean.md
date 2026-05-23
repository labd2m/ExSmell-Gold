```elixir
defmodule Accounts.Authentication do
  @moduledoc """
  Handles user registration, credential storage, and initial profile setup.
  """

  require Logger

  alias Accounts.{User, PasswordHasher, EmailVerifier, Repo}

  @roles [:admin, :editor, :viewer, :guest]
  @default_locale "en"
  @default_timezone "UTC"

  def register_user(
        username,
        email,
        password,
        first_name,
        last_name,
        phone_number,
        role,
        locale,
        timezone,
        email_notifications,
        sms_notifications
      ) do

    with :ok <- validate_username(username),
         :ok <- validate_email(email),
         :ok <- validate_password(password),
         :ok <- validate_role(role),
         {:ok, hashed_password} <- PasswordHasher.hash(password) do

      locale = locale || @default_locale
      timezone = timezone || @default_timezone

      user = %User{
        id: generate_user_id(),
        username: username,
        email: email,
        hashed_password: hashed_password,
        first_name: first_name,
        last_name: last_name,
        phone_number: phone_number,
        role: role,
        locale: locale,
        timezone: timezone,
        preferences: %{
          email_notifications: email_notifications,
          sms_notifications: sms_notifications
        },
        email_verified: false,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      case Repo.insert(user) do
        {:ok, saved_user} ->
          EmailVerifier.send_verification(saved_user.email, saved_user.id)
          Logger.info("New user registered: #{username} (#{email})")
          {:ok, saved_user}

        {:error, changeset} ->
          Logger.warning("Registration failed for #{email}: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end

  def authenticate(email, password) do
    case Repo.get_by(User, email: email) do
      nil ->
        {:error, :not_found}

      user ->
        if PasswordHasher.verify(password, user.hashed_password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  defp validate_username(u) when is_binary(u) and byte_size(u) >= 3, do: :ok
  defp validate_username(_), do: {:error, :invalid_username}

  defp validate_email(e) when is_binary(e) do
    if String.contains?(e, "@"), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_email(_), do: {:error, :invalid_email}

  defp validate_password(p) when is_binary(p) and byte_size(p) >= 8, do: :ok
  defp validate_password(_), do: {:error, :weak_password}

  defp validate_role(r) when r in @roles, do: :ok
  defp validate_role(r), do: {:error, {:invalid_role, r}}

  defp generate_user_id do
    "USR-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end
```
