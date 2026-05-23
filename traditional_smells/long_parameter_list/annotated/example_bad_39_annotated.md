# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Accounts.register_user/10` |
| **Affected function(s)** | `register_user/10` |
| **Short explanation** | The function receives 10 positional parameters to register a new user, mixing personal data, security preferences, and account settings. These groups naturally map to structs (`%RegistrationParams{}`, `%SecuritySettings{}`), and passing them individually makes every call site verbose and fragile. |

```elixir
defmodule Accounts do
  @moduledoc """
  Manages user registration and authentication for the platform.
  """

  require Logger

  @min_password_length 10
  @supported_locales ~w(en pt es fr de)

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 10 individual parameters are passed
  # where grouped structs such as %PersonalInfo{} and %AccountSettings{}
  # would make the function signature self-documenting and reduce the chance
  # of accidentally swapping arguments such as `locale` and `timezone`.
  def register_user(
        first_name,
        last_name,
        email,
        password,
        phone_number,
        locale,
        timezone,
        agreed_to_terms,
        marketing_opt_in,
        referral_code
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_names(first_name, last_name),
         :ok <- validate_email(email),
         :ok <- validate_password(password),
         :ok <- validate_locale(locale),
         :ok <- require_terms_acceptance(agreed_to_terms) do
      hashed_password = hash_password(password)

      user = %{
        id: generate_uuid(),
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        email: String.downcase(String.trim(email)),
        hashed_password: hashed_password,
        phone_number: normalize_phone(phone_number),
        locale: locale,
        timezone: timezone,
        marketing_opt_in: marketing_opt_in,
        referral_code: referral_code,
        role: :member,
        confirmed: false,
        inserted_at: DateTime.utc_now()
      }

      case persist_user(user) do
        {:ok, saved_user} ->
          maybe_apply_referral(saved_user, referral_code)
          send_confirmation_email(saved_user)
          Logger.info("New user registered: #{saved_user.email}")
          {:ok, saved_user}

        {:error, :email_taken} ->
          {:error, :email_already_registered}

        {:error, reason} ->
          Logger.error("Registration failed: #{inspect(reason)}")
          {:error, :registration_failed}
      end
    end
  end

  defp validate_names(first, last) when byte_size(first) > 0 and byte_size(last) > 0, do: :ok
  defp validate_names(_, _), do: {:error, :invalid_names}

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email),
      do: :ok,
      else: {:error, :invalid_email}
  end

  defp validate_password(pwd) when byte_size(pwd) >= @min_password_length, do: :ok
  defp validate_password(_), do: {:error, :password_too_short}

  defp validate_locale(l) when l in @supported_locales, do: :ok
  defp validate_locale(l), do: {:error, "unsupported locale: #{l}"}

  defp require_terms_acceptance(true), do: :ok
  defp require_terms_acceptance(_), do: {:error, :must_accept_terms}

  defp hash_password(pwd) do
    :crypto.hash(:sha256, pwd) |> Base.encode16(case: :lower)
  end

  defp normalize_phone(nil), do: nil
  defp normalize_phone(phone), do: String.replace(phone, ~r/\D/, "")

  defp persist_user(user) do
    {:ok, Map.put(user, :persisted, true)}
  end

  defp maybe_apply_referral(_user, nil), do: :ok
  defp maybe_apply_referral(user, code) do
    Logger.info("Applying referral #{code} for user #{user.id}")
    :ok
  end

  defp send_confirmation_email(user) do
    Logger.debug("Queuing confirmation email to #{user.email}")
    :ok
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
