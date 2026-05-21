# Annotated Example 15

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `PasswordPolicy.validate/1`
- **Affected function(s):** `validate/1`
- **Short explanation:** `PasswordPolicy.validate/1` fetches `:min_length`, `:require_uppercase`, and `:require_special_char` from the application environment. This prevents the library from being used with different policies (e.g., a strict admin account policy vs. a relaxed guest policy) within the same application without global config changes.

## Code

```elixir
defmodule PasswordPolicy do
  @moduledoc """
  A library for enforcing password strength requirements. Validates candidate
  passwords against a configurable policy and returns structured error messages
  suitable for surfacing in registration and change-password flows.

  Configuration in `config/config.exs`:

      config :password_policy,
        min_length: 12,
        require_uppercase: true,
        require_digit: true,
        require_special_char: true
  """

  @special_chars ~r/[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/

  @doc """
  Validates a plaintext password string against the configured policy.

  Returns `{:ok, password}` when all checks pass, or
  `{:error, reasons}` with a list of human-readable failure reasons.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because min_length, require_uppercase, and
  # require_special_char are fetched from the Application Environment instead of
  # being passed as optional keyword arguments. An application with different
  # password policies for different user roles cannot use this function with
  # different constraints without altering global configuration.
  def validate(password) when is_binary(password) do
    min_length = Application.fetch_env!(:password_policy, :min_length)
    require_uppercase = Application.get_env(:password_policy, :require_uppercase, true)
    require_digit = Application.get_env(:password_policy, :require_digit, true)
    require_special = Application.get_env(:password_policy, :require_special_char, false)

    errors =
      []
      |> check_length(password, min_length)
      |> check_uppercase(password, require_uppercase)
      |> check_digit(password, require_digit)
      |> check_special(password, require_special)

    if errors == [] do
      {:ok, password}
    else
      {:error, Enum.reverse(errors)}
    end
  end
  # VALIDATION: SMELL END

  def validate(_), do: {:error, ["Password must be a string"]}

  @doc """
  Returns `true` if the password passes the configured policy.
  """
  def valid?(password), do: match?({:ok, _}, validate(password))

  @doc """
  Raises if the password does not meet policy requirements.
  """
  def validate!(password) do
    case validate(password) do
      {:ok, pw} ->
        pw

      {:error, reasons} ->
        raise ArgumentError, "Invalid password: " <> Enum.join(reasons, "; ")
    end
  end

  @doc """
  Hashes a validated password using bcrypt. Only call after `validate/1` succeeds.
  Delegates to `Bcrypt` (or compatible adapter).
  """
  def hash(password) when is_binary(password) do
    Bcrypt.hash_pwd_salt(password)
  end

  @doc """
  Verifies a plaintext password against a stored hash.
  """
  def verify(password, hash) when is_binary(password) and is_binary(hash) do
    Bcrypt.verify_pass(password, hash)
  end

  ## Private helpers

  defp check_length(errors, password, min) do
    if String.length(password) >= min do
      errors
    else
      ["must be at least #{min} characters long" | errors]
    end
  end

  defp check_uppercase(errors, _password, false), do: errors

  defp check_uppercase(errors, password, true) do
    if String.match?(password, ~r/[A-Z]/) do
      errors
    else
      ["must contain at least one uppercase letter" | errors]
    end
  end

  defp check_digit(errors, _password, false), do: errors

  defp check_digit(errors, password, true) do
    if String.match?(password, ~r/\d/) do
      errors
    else
      ["must contain at least one digit" | errors]
    end
  end

  defp check_special(errors, _password, false), do: errors

  defp check_special(errors, password, true) do
    if String.match?(password, @special_chars) do
      errors
    else
      ["must contain at least one special character" | errors]
    end
  end
end
```
