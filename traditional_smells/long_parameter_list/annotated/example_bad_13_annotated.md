# Annotated Example 13 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Auth.Registration.register_user/8` |
| **Affected function(s)** | `register_user/8` |
| **Explanation** | The function receives 8 separate scalar parameters that collectively describe a new user account. Personal information (first_name, last_name, birth_date), credentials (email, password), and account settings (role, locale, marketing_opt_in) would each form natural groupings. Passing them individually inflates the function signature and makes the order of boolean/string arguments easy to confuse at the call site. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `register_user/8` accepts eight
# individual parameters. The values split naturally into at least two groups:
# personal/credential info and account preferences. Passing them as a flat
# argument list makes the function hard to call correctly (especially the
# trailing booleans and strings) and forces callers to remember exact ordering.
defmodule Auth.Registration do
  @moduledoc """
  Manages new user registration, including validation, hashing, and welcome emails.
  """

  require Logger

  alias Auth.Repo
  alias Auth.Schemas.User
  alias Auth.Mailer
  alias Auth.TokenService

  @valid_roles ~w(admin editor viewer)
  @default_locale "en"

  def register_user(
        first_name,
        last_name,
        email,
        password,
        birth_date,
        role,
        locale,
        marketing_opt_in
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_name(first_name, :first_name),
         :ok <- validate_name(last_name, :last_name),
         :ok <- validate_email(email),
         :ok <- validate_password(password),
         :ok <- validate_birth_date(birth_date),
         :ok <- validate_role(role) do
      hashed_password = Bcrypt.hash_pwd_salt(password)
      effective_locale = if locale in ~w(en pt es fr), do: locale, else: @default_locale

      user_attrs = %{
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        email: String.downcase(String.trim(email)),
        hashed_password: hashed_password,
        birth_date: birth_date,
        role: role,
        locale: effective_locale,
        marketing_opt_in: marketing_opt_in,
        email_verified: false,
        status: :pending,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(User.changeset(%User{}, user_attrs)) do
        {:ok, user} ->
          token = TokenService.generate_verification_token(user.id)
          Mailer.send_welcome_email(user, token)

          if marketing_opt_in do
            Mailer.subscribe_to_newsletter(user.email, effective_locale)
          end

          Logger.info("User registered: #{user.email} with role=#{role}")
          {:ok, user}

        {:error, %{errors: [email: _]} = changeset} ->
          Logger.warn("Registration conflict for #{email}")
          {:error, :email_taken}

        {:error, changeset} ->
          Logger.error("Registration failed: #{inspect(changeset.errors)}")
          {:error, :registration_failed}
      end
    end
  end

  defp validate_name(value, field) do
    if is_binary(value) and String.length(String.trim(value)) >= 1 do
      :ok
    else
      {:error, {field, :blank}}
    end
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_password(password) do
    cond do
      String.length(password) < 8 -> {:error, :password_too_short}
      not Regex.match?(~r/[A-Z]/, password) -> {:error, :password_needs_uppercase}
      not Regex.match?(~r/[0-9]/, password) -> {:error, :password_needs_digit}
      true -> :ok
    end
  end

  defp validate_birth_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} ->
        age = Date.diff(Date.utc_today(), parsed) |> div(365)
        if age >= 13, do: :ok, else: {:error, :too_young}

      {:error, _} ->
        {:error, :invalid_birth_date}
    end
  end

  defp validate_role(role) when role in @valid_roles, do: :ok
  defp validate_role(_), do: {:error, :invalid_role}
end
```
