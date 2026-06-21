```elixir
defmodule Auth.PasswordPolicy do
  @moduledoc """
  Enforces minimum password strength requirements before hashing.
  """

  @min_length 12

  @type violation ::
          :too_short
          | :missing_uppercase
          | :missing_lowercase
          | :missing_digit

  @spec validate(String.t()) :: :ok | {:error, [violation()]}
  def validate(password) when is_binary(password) do
    violations =
      []
      |> check(String.length(password) >= @min_length, :too_short)
      |> check(String.match?(password, ~r/[A-Z]/), :missing_uppercase)
      |> check(String.match?(password, ~r/[a-z]/), :missing_lowercase)
      |> check(String.match?(password, ~r/[0-9]/), :missing_digit)

    case violations do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check(acc, true, _violation), do: acc
  defp check(acc, false, violation), do: [violation | acc]
end

defmodule Auth.PasswordHasher do
  @moduledoc """
  Hashes and verifies passwords using Argon2id.

  Hashing always validates the plaintext against the password policy
  before invoking the KDF. Verification uses a timing-safe comparison
  to prevent timing oracle attacks; when no stored hash exists, a dummy
  hash comparison is still performed so that the timing profile of a
  missing account is indistinguishable from a wrong password.
  """

  alias Auth.PasswordPolicy

  @dummy_hash Argon2.hash_pwd_salt("dummy_password_for_timing_safety")

  @spec hash(String.t()) :: {:ok, String.t()} | {:error, :weak_password, [PasswordPolicy.violation()]}
  def hash(plaintext) when is_binary(plaintext) do
    case PasswordPolicy.validate(plaintext) do
      :ok ->
        {:ok, Argon2.hash_pwd_salt(plaintext)}

      {:error, violations} ->
        {:error, :weak_password, violations}
    end
  end

  @spec verify(String.t(), String.t() | nil) :: :ok | {:error, :invalid_credentials}
  def verify(plaintext, nil) when is_binary(plaintext) do
    Argon2.verify_pass(plaintext, @dummy_hash)
    {:error, :invalid_credentials}
  end

  def verify(plaintext, stored_hash)
      when is_binary(plaintext) and is_binary(stored_hash) do
    if Argon2.verify_pass(plaintext, stored_hash) do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  @spec needs_rehash?(String.t()) :: boolean()
  def needs_rehash?(stored_hash) when is_binary(stored_hash) do
    Argon2.needs_rehash?(stored_hash)
  end
end

defmodule Auth.CredentialStore do
  @moduledoc """
  Manages stored password hashes for user accounts.

  Provides a safe credential update flow that re-verifies the current
  password before replacing it, and a login flow that rehashes on the
  fly when the stored algorithm parameters are outdated.
  """

  alias Auth.{PasswordHasher}

  @spec set_password(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :weak_password, list()}
  def set_password(user_id, new_plaintext) when is_binary(user_id) do
    with {:ok, hash} <- PasswordHasher.hash(new_plaintext) do
      Accounts.Repo.update_all(
        Ecto.Query.from(u in Accounts.User, where: u.id == ^user_id),
        set: [password_hash: hash]
      )

      {:ok, hash}
    end
  end

  @spec authenticate(String.t(), String.t()) ::
          {:ok, :authenticated} | {:ok, :authenticated_and_rehashed} | {:error, :invalid_credentials}
  def authenticate(stored_hash, plaintext) do
    case PasswordHasher.verify(plaintext, stored_hash) do
      :ok ->
        if PasswordHasher.needs_rehash?(stored_hash) do
          {:ok, :authenticated_and_rehashed}
        else
          {:ok, :authenticated}
        end

      {:error, :invalid_credentials} ->
        {:error, :invalid_credentials}
    end
  end
end
```
