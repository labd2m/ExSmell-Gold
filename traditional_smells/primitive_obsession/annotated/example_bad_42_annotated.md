# Annotated Example — Primitive Obsession

## Metadata

- **Smell name:** Primitive Obsession
- **Expected smell location:** `Accounts.UserRegistration` module — function parameters `street`, `city`, `state`, `zip_code`, `country` in `register_user/5` and `update_address/6`, and `phone_number` as a raw string throughout
- **Affected functions:** `register_user/5`, `update_address/6`, `format_mailing_label/1`, `notify_address_change/2`
- **Short explanation:** A user's postal address is decomposed into five separate raw `string` parameters (`street`, `city`, `state`, `zip_code`, `country`) and a phone number is a raw `string`, instead of being wrapped in dedicated `Address` and `PhoneNumber` structs. This spreads address-handling logic all over the module, makes function signatures unwieldy, and removes any structural validation at the type boundary.

---

```elixir
defmodule Accounts.UserRegistration do
  @moduledoc """
  Manages user registration and profile address updates for the
  e-commerce accounts system.
  """

  require Logger
  alias Accounts.Repo
  alias Accounts.User

  @country_codes ["US", "CA", "GB", "BR", "AU", "DE", "FR"]

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because the concept of a postal `Address` is
  # dissolved into five separate `string` primitives (`street`, `city`, `state`,
  # `zip_code`, `country`) instead of being represented as a dedicated `Address`
  # struct. Similarly, `phone_number` is a raw string with no type wrapper.
  # This forces every caller to juggle five arguments where one would do, and
  # duplicates validation logic wherever addresses are handled.
  @spec register_user(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def register_user(email, phone_number, street, city, country)
      when is_binary(email) and is_binary(phone_number) and
             is_binary(street) and is_binary(city) and is_binary(country) do
    with :ok <- validate_email(email),
         :ok <- validate_phone(phone_number),
         :ok <- validate_country(country),
         :ok <- validate_street(street) do
      attrs = %{
        email: String.downcase(email),
        phone_number: normalize_phone(phone_number),
        street: String.trim(street),
        city: String.trim(city),
        country: String.upcase(country),
        registered_at: DateTime.utc_now(),
        status: "active"
      }

      case Repo.insert(User.changeset(%User{}, attrs)) do
        {:ok, user} ->
          Logger.info("Registered new user #{user.id} from #{city}, #{country}")
          {:ok, user}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def register_user(_, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec update_address(User.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, String.t()}
  def update_address(%User{} = user, street, city, state, zip_code, country)
      when is_binary(street) and is_binary(city) and is_binary(state) and
             is_binary(zip_code) and is_binary(country) do
    with :ok <- validate_country(country),
         :ok <- validate_zip(zip_code, country),
         :ok <- validate_street(street) do
      attrs = %{
        street: String.trim(street),
        city: String.trim(city),
        state: String.trim(state),
        zip_code: String.replace(zip_code, " ", ""),
        country: String.upcase(country)
      }

      case Repo.update(User.address_changeset(user, attrs)) do
        {:ok, updated_user} ->
          notify_address_change(updated_user, country)
          {:ok, updated_user}

        {:error, _} ->
          {:error, "address_update_failed"}
      end
    end
  end

  def update_address(_, _, _, _, _, _), do: {:error, "invalid_arguments"}
  # VALIDATION: SMELL END

  @spec format_mailing_label(User.t()) :: String.t()
  def format_mailing_label(%User{} = user) do
    """
    #{user.full_name}
    #{user.street}
    #{user.city}, #{user.state} #{user.zip_code}
    #{user.country}
    """
  end

  defp notify_address_change(user, country) do
    message =
      if country != user.country do
        "Address updated — international address change detected."
      else
        "Address updated successfully."
      end

    Logger.info("User #{user.id}: #{message}")
  end

  defp validate_email(email) do
    if String.contains?(email, "@") and String.length(email) >= 5 do
      :ok
    else
      {:error, "invalid_email"}
    end
  end

  defp validate_phone(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    if String.length(digits) >= 7 and String.length(digits) <= 15 do
      :ok
    else
      {:error, "invalid_phone_number"}
    end
  end

  defp normalize_phone(phone), do: String.replace(phone, ~r/\D/, "")

  defp validate_country(code) when code in @country_codes, do: :ok
  defp validate_country(_), do: {:error, "unsupported_country"}

  defp validate_street(street) when byte_size(street) >= 5, do: :ok
  defp validate_street(_), do: {:error, "street_too_short"}

  defp validate_zip(zip, "US") do
    if Regex.match?(~r/^\d{5}(-\d{4})?$/, zip), do: :ok, else: {:error, "invalid_us_zip"}
  end

  defp validate_zip(zip, "CA") do
    if Regex.match?(~r/^[A-Z]\d[A-Z] ?\d[A-Z]\d$/i, zip),
      do: :ok,
      else: {:error, "invalid_ca_postal"}
  end

  defp validate_zip(zip, _) when byte_size(zip) >= 3, do: :ok
  defp validate_zip(_, _), do: {:error, "invalid_zip_code"}
end
```
