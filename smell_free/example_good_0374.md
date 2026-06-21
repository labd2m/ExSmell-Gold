```elixir
defmodule Accounts.Credentials do
  @moduledoc """
  Manages password-based credentials for user accounts. All password values
  are hashed with Bcrypt before persistence; plaintext passwords never touch
  the database. Provides registration, verification, and rotation operations
  with explicit, typed return values at every failure boundary.
  """

  alias Accounts.{Credential, Repo, User}
  alias Ecto.Multi

  @type registration_attrs :: %{
          required(:user_id) => binary(),
          required(:password) => String.t()
        }

  @type rotation_attrs :: %{
          required(:current_password) => String.t(),
          required(:new_password) => String.t()
        }

  @min_password_length 12

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new credential record for an existing user. Validates that the
  password meets minimum requirements and that no credential already exists
  for the user. Returns `{:ok, credential}` or `{:error, reason}`.
  """
  @spec register(registration_attrs()) :: {:ok, Credential.t()} | {:error, term()}
  def register(%{user_id: user_id, password: password})
      when is_binary(user_id) and is_binary(password) do
    with :ok <- validate_password_strength(password),
         :ok <- assert_no_existing_credential(user_id),
         {:ok, credential} <- insert_credential(user_id, password) do
      {:ok, credential}
    end
  end

  def register(_attrs), do: {:error, :invalid_params}

  # ---------------------------------------------------------------------------
  # Verification
  # ---------------------------------------------------------------------------

  @doc """
  Verifies that `password` matches the stored credential for `user_id`.
  Returns `{:ok, credential}` on success or `{:error, :invalid_credentials}`
  on mismatch, using constant-time comparison to prevent timing attacks.
  Always performs the hash comparison even when no credential exists to
  avoid user-enumeration via response timing.
  """
  @spec verify(binary(), String.t()) :: {:ok, Credential.t()} | {:error, :invalid_credentials}
  def verify(user_id, password) when is_binary(user_id) and is_binary(password) do
    credential = Repo.get_by(Credential, user_id: user_id)
    check_password(credential, password)
  end

  def verify(_user_id, _password), do: {:error, :invalid_credentials}

  # ---------------------------------------------------------------------------
  # Password rotation
  # ---------------------------------------------------------------------------

  @doc """
  Rotates the password for a user after verifying the current credential.
  Old and new credential records are swapped inside a single transaction so
  there is never a window where no valid credential exists.
  """
  @spec rotate(binary(), rotation_attrs()) :: {:ok, Credential.t()} | {:error, term()}
  def rotate(user_id, %{current_password: current, new_password: new_pass})
      when is_binary(user_id) and is_binary(current) and is_binary(new_pass) do
    with {:ok, credential} <- verify(user_id, current),
         :ok <- validate_password_strength(new_pass),
         {:ok, updated} <- swap_credential(credential, new_pass) do
      {:ok, updated}
    end
  end

  def rotate(_user_id, _attrs), do: {:error, :invalid_params}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_password_strength(password) when byte_size(password) >= @min_password_length do
    cond do
      not Regex.match?(~r/[A-Z]/, password) -> {:error, :password_missing_uppercase}
      not Regex.match?(~r/[0-9]/, password) -> {:error, :password_missing_digit}
      not Regex.match?(~r/[^A-Za-z0-9]/, password) -> {:error, :password_missing_symbol}
      true -> :ok
    end
  end

  defp validate_password_strength(_), do: {:error, :password_too_short}

  defp assert_no_existing_credential(user_id) do
    case Repo.get_by(Credential, user_id: user_id) do
      nil -> :ok
      _existing -> {:error, :credential_already_exists}
    end
  end

  defp insert_credential(user_id, password) do
    hash = Bcrypt.hash_pwd_salt(password)

    %Credential{}
    |> Credential.changeset(%{user_id: user_id, password_hash: hash})
    |> Repo.insert()
  end

  defp check_password(nil, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp check_password(%Credential{} = credential, password) do
    if Bcrypt.verify_pass(password, credential.password_hash) do
      {:ok, credential}
    else
      {:error, :invalid_credentials}
    end
  end

  defp swap_credential(old_credential, new_password) do
    new_hash = Bcrypt.hash_pwd_salt(new_password)

    Multi.new()
    |> Multi.delete(:old, old_credential)
    |> Multi.insert(:new, Credential.changeset(%Credential{}, %{
         user_id: old_credential.user_id,
         password_hash: new_hash
       }))
    |> Repo.transaction()
    |> case do
      {:ok, %{new: credential}} -> {:ok, credential}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end
end
```
