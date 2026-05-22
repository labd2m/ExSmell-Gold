```elixir
defmodule UserManagement.PasswordPolicy do
  @moduledoc """
  Enforces password quality rules for user account management.
  Validates strength, hashes credentials, and manages password
  change workflows including breach-history checks.
  """

  require Logger

  @min_password_length Application.fetch_env!(:user_management, :min_password_length)

  @hash_algorithm :argon2id
  @hash_time_cost 3
  @hash_memory_cost 65_536
  @max_history_check 5

  @special_chars ~r/[!@#\$%\^&\*\(\)\-_=\+\[\]{};:'",<>\.?\/\\|`~]/

  @type validation_error ::
          :too_short
          | :no_uppercase
          | :no_lowercase
          | :no_digit
          | :no_special_char
          | :common_password

  @spec validate_password(String.t()) :: :ok | {:error, [validation_error()]}
  def validate_password(password) when is_binary(password) do
    errors =
      []
      |> check_length(password)
      |> check_uppercase(password)
      |> check_lowercase(password)
      |> check_digit(password)
      |> check_special(password)
      |> check_common(password)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @spec hash_password(String.t()) :: {:ok, String.t()} | {:error, :hashing_failed}
  def hash_password(password) when is_binary(password) do
    case Argon2.hash_pwd_salt(password,
           t_cost: @hash_time_cost,
           m_cost: @hash_memory_cost
         ) do
      hash when is_binary(hash) -> {:ok, hash}
      _ -> {:error, :hashing_failed}
    end
  rescue
    e ->
      Logger.error("Password hashing error", reason: inspect(e))
      {:error, :hashing_failed}
  end

  @spec verify_password(String.t(), String.t()) :: boolean()
  def verify_password(password, hash) when is_binary(password) and is_binary(hash) do
    Argon2.verify_pass(password, hash)
  rescue
    _ -> false
  end

  @spec change_password(String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :weak_password | :reused_password | :hashing_failed}
  def change_password(user_id, new_password, recent_hashes \\ []) do
    with :ok <- validate_password(new_password),
         :ok <- check_reuse(new_password, recent_hashes),
         {:ok, new_hash} <- hash_password(new_password) do
      Logger.info("Password changed", user_id: user_id)
      {:ok, new_hash}
    else
      {:error, errors} when is_list(errors) ->
        Logger.warning("Weak password rejected", user_id: user_id, errors: errors)
        {:error, :weak_password}

      {:error, :reused} ->
        Logger.warning("Password reuse rejected", user_id: user_id)
        {:error, :reused_password}

      {:error, :hashing_failed} ->
        {:error, :hashing_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Private validation helpers
  # ---------------------------------------------------------------------------

  defp check_length(errors, pwd) do
    if String.length(pwd) >= @min_password_length, do: errors, else: [:too_short | errors]
  end

  defp check_uppercase(errors, pwd) do
    if String.match?(pwd, ~r/[A-Z]/), do: errors, else: [:no_uppercase | errors]
  end

  defp check_lowercase(errors, pwd) do
    if String.match?(pwd, ~r/[a-z]/), do: errors, else: [:no_lowercase | errors]
  end

  defp check_digit(errors, pwd) do
    if String.match?(pwd, ~r/[0-9]/), do: errors, else: [:no_digit | errors]
  end

  defp check_special(errors, pwd) do
    if String.match?(pwd, @special_chars), do: errors, else: [:no_special_char | errors]
  end

  defp check_common(errors, pwd) do
    if pwd in common_passwords(), do: [:common_password | errors], else: errors
  end

  defp check_reuse(password, recent_hashes) do
    reused? =
      recent_hashes
      |> Enum.take(@max_history_check)
      |> Enum.any?(&verify_password(password, &1))

    if reused?, do: {:error, :reused}, else: :ok
  end

  defp common_passwords do
    Application.get_env(:user_management, :common_passwords, [
      "password",
      "123456",
      "qwerty",
      "letmein",
      "welcome"
    ])
  end
end
```
