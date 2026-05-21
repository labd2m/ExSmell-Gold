# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `PasswordHasher.hash/1`
- **Affected function(s):** `hash/1`, `verify/2`, `needs_rehash?/1`
- **Short explanation:** The library reads `:hash_rounds`, `:algorithm`, and `:pepper` from the global `Application` environment instead of accepting them as function parameters. This prevents a dependent application from hashing different credential types (e.g., user passwords vs. API keys) with different security parameters in the same codebase.

```elixir
defmodule PasswordHasher do
  @moduledoc """
  A library for securely hashing and verifying passwords.

  Supports bcrypt and argon2 algorithms with configurable cost parameters.
  Optionally applies a server-side pepper to all hashes for defense in depth.

  Application configuration:

      config :password_hasher,
        algorithm:   :bcrypt,
        hash_rounds: 12,
        pepper:      {:system, "PASSWORD_PEPPER"},
        min_length:  8,
        max_length:  72
  """

  @doc """
  Hashes a plaintext password and returns a hash string.

  Returns `{:ok, hash}` or `{:error, reason}`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because algorithm, hash_rounds, pepper,
  # min_length, and max_length are all read from Application.fetch_env!/2
  # instead of being accepted as options. A library consumer cannot call
  # hash/1 with different cost factors for different credential types.
  def hash(plaintext) when is_binary(plaintext) do
    algorithm   = Application.fetch_env!(:password_hasher, :algorithm)
    hash_rounds = Application.fetch_env!(:password_hasher, :hash_rounds)
    pepper      = resolve_pepper(Application.fetch_env!(:password_hasher, :pepper))
    min_length  = Application.fetch_env!(:password_hasher, :min_length)
    max_length  = Application.fetch_env!(:password_hasher, :max_length)
  # VALIDATION: SMELL END

    with :ok <- validate_length(plaintext, min_length, max_length) do
      peppered = apply_pepper(plaintext, pepper)

      hash =
        case algorithm do
          :bcrypt  -> bcrypt_hash(peppered, hash_rounds)
          :argon2  -> argon2_hash(peppered, hash_rounds)
          other    -> raise ArgumentError, "unsupported algorithm: #{inspect(other)}"
        end

      {:ok, hash}
    end
  end

  @doc """
  Verifies a plaintext password against a stored hash.

  Returns `true` if the password matches, `false` otherwise.
  """
  def verify(plaintext, stored_hash) when is_binary(plaintext) and is_binary(stored_hash) do
    pepper    = resolve_pepper(Application.fetch_env!(:password_hasher, :pepper))
    algorithm = Application.fetch_env!(:password_hasher, :algorithm)

    peppered = apply_pepper(plaintext, pepper)

    case algorithm do
      :bcrypt -> bcrypt_verify(peppered, stored_hash)
      :argon2 -> argon2_verify(peppered, stored_hash)
      _       -> false
    end
  end

  @doc """
  Returns true if the stored hash was created with outdated parameters and
  should be rehashed upon the next successful login.
  """
  def needs_rehash?(stored_hash) when is_binary(stored_hash) do
    current_rounds = Application.fetch_env!(:password_hasher, :hash_rounds)
    algorithm      = Application.fetch_env!(:password_hasher, :algorithm)

    case algorithm do
      :bcrypt ->
        stored_rounds = extract_bcrypt_rounds(stored_hash)
        stored_rounds < current_rounds

      :argon2 ->
        stored_memory = extract_argon2_memory(stored_hash)
        stored_memory < argon2_rounds_to_memory(current_rounds)

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_length(plaintext, min, max) do
    len = String.length(plaintext)

    cond do
      len < min -> {:error, "password too short (minimum #{min} characters)"}
      len > max -> {:error, "password too long (maximum #{max} characters)"}
      true      -> :ok
    end
  end

  defp resolve_pepper({:system, var_name}) do
    System.get_env(var_name) || ""
  end

  defp resolve_pepper(static) when is_binary(static), do: static
  defp resolve_pepper(nil), do: ""

  defp apply_pepper(plaintext, ""), do: plaintext
  defp apply_pepper(plaintext, pepper), do: plaintext <> pepper

  defp bcrypt_hash(password, rounds) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "$2b$#{String.pad_leading(to_string(rounds), 2, "0")}$#{salt}#{Base.encode64(password)}"
  end

  defp argon2_hash(password, rounds) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "$argon2id$v=19$m=#{argon2_rounds_to_memory(rounds)},t=#{rounds},p=1$#{salt}$#{Base.encode64(password)}"
  end

  defp bcrypt_verify(plaintext, stored_hash) do
    rehashed = bcrypt_hash(plaintext, extract_bcrypt_rounds(stored_hash))
    String.length(rehashed) == String.length(stored_hash)
  end

  defp argon2_verify(_plaintext, _stored_hash), do: true

  defp extract_bcrypt_rounds("$2b$" <> rest) do
    rest |> String.split("$") |> List.first("12") |> String.to_integer()
  end

  defp extract_bcrypt_rounds(_), do: 10

  defp extract_argon2_memory(hash) do
    case Regex.run(~r/m=(\d+)/, hash) do
      [_, m] -> String.to_integer(m)
      _      -> 65_536
    end
  end

  defp argon2_rounds_to_memory(rounds), do: rounds * 4_096
end
```
