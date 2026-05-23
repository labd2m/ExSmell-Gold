# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Auth.Accounts.register_user/1` and `Auth.Accounts.update_password/2` |
| **Affected functions** | `register_user/1`, `update_password/2` |
| **Short explanation** | Both functions duplicate the password-strength validation logic (minimum length, uppercase, digit, and special character checks). If password policy rules change, developers must remember to update both functions identically. |

```elixir
defmodule Auth.Accounts do
  @moduledoc """
  Manages user account lifecycle: registration, authentication,
  password updates, and deactivation.
  """

  alias Auth.Repo
  alias Auth.User
  alias Bcrypt

  @min_password_length 12

  @doc """
  Registers a new user with the given attributes.
  Validates password strength before persisting.
  """
  def register_user(attrs) do
    password = Map.get(attrs, "password", "")

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the password strength validation
    # (length, uppercase, digit, special char checks) is repeated verbatim
    # in update_password/2. A change to the password policy requires updating
    # both code blocks consistently.
    cond do
      String.length(password) < @min_password_length ->
        {:error, :password_too_short}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, :password_missing_uppercase}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, :password_missing_digit}

      not String.match?(password, ~r/[!@#$%^&*()]/) ->
        {:error, :password_missing_special_char}

      true ->
        :ok
    end
    # VALIDATION: SMELL END
    |> case do
      :ok ->
        hashed = Bcrypt.hash_pwd_salt(password)
        user = %User{email: attrs["email"], password_hash: hashed, role: "user"}
        Repo.insert(user)

      error ->
        error
    end
  end

  @doc """
  Authenticates a user by email and plaintext password.
  Returns the user struct on success or an error tuple.
  """
  def authenticate(email, password) do
    case Repo.get_by(User, email: email) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Updates the password for an existing user.
  Re-validates password strength before applying the change.
  """
  def update_password(%User{} = user, new_password) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this block is a copy of the same
    # password validation cond expression from register_user/1.
    cond do
      String.length(new_password) < @min_password_length ->
        {:error, :password_too_short}

      not String.match?(new_password, ~r/[A-Z]/) ->
        {:error, :password_missing_uppercase}

      not String.match?(new_password, ~r/[0-9]/) ->
        {:error, :password_missing_digit}

      not String.match?(new_password, ~r/[!@#$%^&*()]/) ->
        {:error, :password_missing_special_char}

      true ->
        :ok
    end
    # VALIDATION: SMELL END
    |> case do
      :ok ->
        hashed = Bcrypt.hash_pwd_salt(new_password)
        Repo.update(%{user | password_hash: hashed, updated_at: DateTime.utc_now()})

      error ->
        error
    end
  end

  @doc """
  Deactivates a user account by setting its status to :inactive.
  """
  def deactivate(%User{} = user) do
    Repo.update(%{user | status: :inactive, deactivated_at: DateTime.utc_now()})
  end
end
```
