```elixir
defmodule AuthValidator do
  @moduledoc """
  Provides input validation helpers used during user registration
  and authentication flows.
  """

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @min_password_length 8

  defmacro validate_email(email) do
    quote do
      email_value = unquote(email)
      Regex.match?(@email_regex, email_value)
    end
  end

  @doc """
  Validates that a password meets minimum security requirements.
  Returns `{:ok, password}` or `{:error, reason}`.
  """
  @spec validate_password(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_password(password) when is_binary(password) do
    cond do
      String.length(password) < @min_password_length ->
        {:error, "Password must be at least #{@min_password_length} characters"}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, "Password must contain at least one uppercase letter"}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, "Password must contain at least one digit"}

      true ->
        {:ok, password}
    end
  end

  @doc """
  Validates that a username is between 3 and 32 characters and only
  contains alphanumeric characters or underscores.
  """
  @spec validate_username(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_username(username) when is_binary(username) do
    cond do
      String.length(username) < 3 ->
        {:error, "Username must be at least 3 characters"}

      String.length(username) > 32 ->
        {:error, "Username must not exceed 32 characters"}

      not String.match?(username, ~r/^\w+$/) ->
        {:error, "Username may only contain letters, digits, and underscores"}

      true ->
        {:ok, username}
    end
  end
end

defmodule Auth.RegistrationService do
  @moduledoc """
  Handles new user registration, including input validation,
  password hashing, and persisting the new account record.
  """

  require AuthValidator

  alias Auth.UserRepository

  @doc """
  Validates and registers a new user account.
  Returns `{:ok, user}` on success or `{:error, reason}` on failure.
  """
  @spec register(map()) :: {:ok, map()} | {:error, String.t()}
  def register(%{"email" => email, "password" => password, "username" => username}) do
    with true <- AuthValidator.validate_email(email),
         {:ok, _} <- AuthValidator.validate_password(password),
         {:ok, _} <- AuthValidator.validate_username(username) do
      hashed = hash_password(password)

      UserRepository.insert(%{
        email: email,
        username: username,
        password_hash: hashed,
        inserted_at: DateTime.utc_now()
      })
    else
      false -> {:error, "Invalid email address"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hash_password(password) do
    :crypto.hash(:sha256, password) |> Base.encode16(case: :lower)
  end
end
```
