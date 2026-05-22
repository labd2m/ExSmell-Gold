# Annotated Bad Example 13

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@bcrypt_cost` defined at the top of `UserManagement.PasswordService`
- **Affected function(s):** `hash_password/1`, `verify_password/2`, `rehash_if_needed/3`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to set the bcrypt cost factor as a module attribute. Since module attributes are evaluated at compile-time and the Application Environment may not be available then, Elixir can raise a compilation warning or an `ArgumentError`.

---

```elixir
defmodule UserManagement.PasswordService do
  @moduledoc """
  Handles secure password hashing and verification using bcrypt.
  Provides helpers for detecting outdated hashes that should be
  transparently rehashed on the next successful login.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called at
  # VALIDATION: module-definition time to populate a module attribute. Module
  # VALIDATION: attributes are evaluated during compilation; the :user_management
  # VALIDATION: Application Environment is not yet loaded at that point, so Elixir
  # VALIDATION: may emit a warning or raise ArgumentError during compilation.
  @bcrypt_cost Application.fetch_env!(:user_management, :bcrypt_cost)
  # VALIDATION: SMELL END

  @min_password_length 12
  @max_password_length 128
  @pepper_key :password_pepper

  @type hash_result :: {:ok, String.t()} | {:error, :too_short | :too_long | :empty}
  @type verify_result :: {:ok, :valid} | {:error, :invalid}

  @doc """
  Hashes a plaintext password using bcrypt with the configured cost factor.

  Applies a server-side pepper before hashing to make offline dictionary
  attacks harder even if the hash database is leaked.

  ## Parameters
    - `plaintext` - The user-supplied password string.

  ## Returns
    - `{:ok, hash_string}` on success.
    - `{:error, :too_short}` if the password is under #{@min_password_length} characters.
    - `{:error, :too_long}` if it exceeds #{@max_password_length} characters.
  """
  @spec hash_password(String.t()) :: hash_result()
  def hash_password(plaintext) when is_binary(plaintext) do
    with :ok <- validate_length(plaintext) do
      peppered = apply_pepper(plaintext)
      hash = Bcrypt.hash_pwd_salt(peppered, log_rounds: @bcrypt_cost)
      Logger.debug("Password hashed bcrypt_cost=#{@bcrypt_cost}")
      {:ok, hash}
    end
  end

  @doc """
  Verifies that `plaintext` matches the stored `hash`.

  Always runs through the full bcrypt comparison to avoid timing attacks,
  even when the password is obviously wrong.

  ## Parameters
    - `plaintext` - The candidate password to check.
    - `hash` - The stored bcrypt hash string.
  """
  @spec verify_password(String.t(), String.t()) :: verify_result()
  def verify_password(plaintext, hash) when is_binary(plaintext) and is_binary(hash) do
    peppered = apply_pepper(plaintext)

    if Bcrypt.verify_pass(peppered, hash) do
      {:ok, :valid}
    else
      {:error, :invalid}
    end
  end

  @doc """
  Checks whether a stored hash was created with an outdated cost factor and,
  if so, hashes the password afresh and calls `update_fn` with the new hash.

  Intended to be called on every successful login to transparently upgrade
  legacy hashes without requiring a forced password reset.

  ## Parameters
    - `plaintext` - The plaintext password (verified to be correct before calling this).
    - `stored_hash` - The hash currently in the database.
    - `update_fn` - A one-arity function that persists the new hash; returns `:ok`.
  """
  @spec rehash_if_needed(String.t(), String.t(), (String.t() -> :ok)) :: :ok
  def rehash_if_needed(plaintext, stored_hash, update_fn)
      when is_binary(plaintext) and is_binary(stored_hash) and is_function(update_fn, 1) do
    stored_cost = extract_cost(stored_hash)

    if stored_cost < @bcrypt_cost do
      Logger.info("Rehashing password old_cost=#{stored_cost} new_cost=#{@bcrypt_cost}")

      case hash_password(plaintext) do
        {:ok, new_hash} -> update_fn.(new_hash)
        _ -> :ok
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_length(password) do
    cond do
      String.length(password) < @min_password_length -> {:error, :too_short}
      String.length(password) > @max_password_length -> {:error, :too_long}
      true -> :ok
    end
  end

  defp apply_pepper(plaintext) do
    pepper = Application.get_env(:user_management, @pepper_key, "")
    plaintext <> pepper
  end

  defp extract_cost("$2" <> rest) do
    case Regex.run(~r/^\$[a-z]\$(\d{2})\$/, "$2" <> rest) do
      [_, cost_str] -> String.to_integer(cost_str)
      _ -> @bcrypt_cost
    end
  end

  defp extract_cost(_), do: @bcrypt_cost
end
```
