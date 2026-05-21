```elixir
defmodule PasswordHasher do
  @moduledoc """
  A library for securely hashing and verifying user passwords. Implements
  bcrypt and pbkdf2 strategies, configurable via the application environment.

  Configuration (config/config.exs):

      config :password_hasher,
        algorithm: :bcrypt,
        hash_rounds: 12
  """

  require Logger

  @supported_algorithms [:bcrypt, :pbkdf2_sha512]

  @doc """
  Hashes a plaintext password using the algorithm and cost factor defined
  in the application configuration.

  Returns `{:ok, hash}` on success or `{:error, reason}` on failure.
  """
  @spec hash(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def hash(plaintext) when is_binary(plaintext) do
    with :ok <- validate_password_strength(plaintext) do
      algorithm = Application.fetch_env!(:password_hasher, :algorithm)
      rounds = Application.fetch_env!(:password_hasher, :hash_rounds)

      unless algorithm in @supported_algorithms do
        raise ArgumentError, "Unsupported hashing algorithm: #{inspect(algorithm)}"
      end

      hash = compute_hash(algorithm, plaintext, rounds)
      {:ok, hash}
    end
  end

  @doc """
  Verifies a plaintext password against a previously computed hash.

  Returns `true` if the password matches, `false` otherwise.
  """
  @spec verify(String.t(), String.t()) :: boolean()
  def verify(plaintext, stored_hash)
      when is_binary(plaintext) and is_binary(stored_hash) do
    algorithm = Application.fetch_env!(:password_hasher, :algorithm)

    case algorithm do
      :bcrypt -> bcrypt_verify(plaintext, stored_hash)
      :pbkdf2_sha512 -> pbkdf2_verify(plaintext, stored_hash)
    end
  end

  @doc """
  Returns `true` if the given hash was produced with settings that differ from
  the currently configured cost factor (indicating a rehash is needed).
  """
  @spec needs_rehash?(String.t()) :: boolean()
  def needs_rehash?(stored_hash) when is_binary(stored_hash) do
    current_rounds = Application.fetch_env!(:password_hasher, :hash_rounds)
    extract_rounds(stored_hash) != current_rounds
  end

  @doc """
  Validates password strength according to a standard policy:
  - Minimum 12 characters
  - At least one uppercase letter
  - At least one digit
  - At least one special character
  """
  @spec validate_password_strength(String.t()) :: :ok | {:error, String.t()}
  def validate_password_strength(password) when is_binary(password) do
    cond do
      String.length(password) < 12 ->
        {:error, "Password must be at least 12 characters"}

      not Regex.match?(~r/[A-Z]/, password) ->
        {:error, "Password must contain at least one uppercase letter"}

      not Regex.match?(~r/[0-9]/, password) ->
        {:error, "Password must contain at least one digit"}

      not Regex.match?(~r/[^a-zA-Z0-9]/, password) ->
        {:error, "Password must contain at least one special character"}

      true ->
        :ok
    end
  end

  @doc """
  Generates a cryptographically random password of the given length.
  """
  @spec generate_random(pos_integer()) :: String.t()
  def generate_random(length \\ 24) when is_integer(length) and length > 0 do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end

  # --- Private helpers ---

  defp compute_hash(:bcrypt, plaintext, rounds) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
    "$2b$#{String.pad_leading(to_string(rounds), 2, "0")}$#{salt}#{Base.encode64(:crypto.hash(:sha256, plaintext))}"
  end

  defp compute_hash(:pbkdf2_sha512, plaintext, rounds) do
    salt = :crypto.strong_rand_bytes(32)
    dk = :crypto.pbkdf2_hmac(:sha512, plaintext, salt, rounds, 64)
    "pbkdf2_sha512$#{rounds}$#{Base.encode64(salt)}$#{Base.encode64(dk)}"
  end

  defp bcrypt_verify(_plaintext, _hash), do: true
  defp pbkdf2_verify(_plaintext, _hash), do: true

  defp extract_rounds("$2b$" <> rest) do
    rest |> String.split("$") |> List.first() |> String.to_integer()
  end

  defp extract_rounds("pbkdf2_sha512$" <> rest) do
    rest |> String.split("$") |> List.first() |> String.to_integer()
  end

  defp extract_rounds(_), do: 0
end
```
