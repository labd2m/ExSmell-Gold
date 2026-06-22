```elixir
defmodule Identity.PasswordPolicy do
  @moduledoc """
  Enforces password strength requirements for user account credentials.

  Policy rules are evaluated as a composable list of named checks.
  Each check returns either `:ok` or `{:error, rule_name, message}`.
  The aggregate result reports all failures rather than halting on
  the first violation.
  """

  @type password :: String.t()
  @type policy_violation :: {atom(), String.t()}
  @type policy_result :: :ok | {:error, [policy_violation()]}

  @minimum_length 12
  @maximum_length 128

  @checks [
    :check_minimum_length,
    :check_maximum_length,
    :check_uppercase,
    :check_lowercase,
    :check_digit,
    :check_special_character,
    :check_no_whitespace,
    :check_not_common
  ]

  @common_passwords ~w(password123 letmein qwerty123 iloveyou welcome1)

  @doc """
  Validates a password against the full policy rule set.

  Returns `:ok` if the password satisfies all rules, or
  `{:error, violations}` listing every rule that was not met.
  """
  @spec validate(password()) :: policy_result()
  def validate(password) when is_binary(password) do
    violations =
      @checks
      |> Enum.map(&apply(__MODULE__, &1, [password]))
      |> Enum.filter(&(&1 != :ok))
      |> Enum.map(fn {:error, rule, message} -> {rule, message} end)

    case violations do
      [] -> :ok
      list -> {:error, list}
    end
  end

  @doc false
  @spec check_minimum_length(password()) :: :ok | {:error, atom(), String.t()}
  def check_minimum_length(password) do
    if String.length(password) >= @minimum_length do
      :ok
    else
      {:error, :too_short, "Password must be at least #{@minimum_length} characters."}
    end
  end

  @doc false
  @spec check_maximum_length(password()) :: :ok | {:error, atom(), String.t()}
  def check_maximum_length(password) do
    if String.length(password) <= @maximum_length do
      :ok
    else
      {:error, :too_long, "Password must not exceed #{@maximum_length} characters."}
    end
  end

  @doc false
  @spec check_uppercase(password()) :: :ok | {:error, atom(), String.t()}
  def check_uppercase(password) do
    if String.match?(password, ~r/[A-Z]/) do
      :ok
    else
      {:error, :no_uppercase, "Password must contain at least one uppercase letter."}
    end
  end

  @doc false
  @spec check_lowercase(password()) :: :ok | {:error, atom(), String.t()}
  def check_lowercase(password) do
    if String.match?(password, ~r/[a-z]/) do
      :ok
    else
      {:error, :no_lowercase, "Password must contain at least one lowercase letter."}
    end
  end

  @doc false
  @spec check_digit(password()) :: :ok | {:error, atom(), String.t()}
  def check_digit(password) do
    if String.match?(password, ~r/[0-9]/) do
      :ok
    else
      {:error, :no_digit, "Password must contain at least one digit."}
    end
  end

  @doc false
  @spec check_special_character(password()) :: :ok | {:error, atom(), String.t()}
  def check_special_character(password) do
    if String.match?(password, ~r/[!@#$%^&*()\-_=+\[\]{}|;:'",.<>?\/\\`~]/) do
      :ok
    else
      {:error, :no_special_character, "Password must contain at least one special character."}
    end
  end

  @doc false
  @spec check_no_whitespace(password()) :: :ok | {:error, atom(), String.t()}
  def check_no_whitespace(password) do
    if String.match?(password, ~r/\s/) do
      {:error, :contains_whitespace, "Password must not contain spaces or whitespace."}
    else
      :ok
    end
  end

  @doc false
  @spec check_not_common(password()) :: :ok | {:error, atom(), String.t()}
  def check_not_common(password) do
    lowered = String.downcase(password)

    if lowered in @common_passwords do
      {:error, :common_password, "Password is too commonly used and cannot be accepted."}
    else
      :ok
    end
  end
end
```
