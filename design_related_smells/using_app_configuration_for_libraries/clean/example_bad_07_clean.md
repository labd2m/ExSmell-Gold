```elixir
defmodule PasswordPolicy do
  @moduledoc """
  A password validation library that enforces configurable strength rules.
  Used in user registration, password reset, and admin provisioning flows.
  """

  @special_chars ~r/[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/

  defmodule ValidationResult do
    defstruct valid?: false, errors: []
  end

  @doc """
  Validates a plaintext password against the configured policy rules.

  Returns a `ValidationResult` indicating whether the password passes
  all configured constraints.

  ## Example

      result = PasswordPolicy.validate("S3cur3P@ss!")
      result.valid? #=> true
  """
  def validate(password) when is_binary(password) do
    min_length        = Application.fetch_env!(:password_policy, :min_length)
    require_uppercase = Application.fetch_env!(:password_policy, :require_uppercase)
    require_digit     = Application.fetch_env!(:password_policy, :require_digit)
    require_special   = Application.fetch_env!(:password_policy, :require_special)

    errors =
      []
      |> check_length(password, min_length)
      |> check_uppercase(password, require_uppercase)
      |> check_digit(password, require_digit)
      |> check_special(password, require_special)

    %ValidationResult{valid?: errors == [], errors: errors}
  end

  @doc """
  Returns true if the password meets the configured policy.
  """
  def valid?(password), do: validate(password).valid?

  @doc """
  Computes a basic strength score for UI feedback (0-4).
  Does not depend on configuration — purely heuristic.
  """
  def strength_score(password) when is_binary(password) do
    [
      String.length(password) >= 8,
      String.length(password) >= 12,
      Regex.match?(~r/[A-Z]/, password),
      Regex.match?(~r/[0-9]/, password),
      Regex.match?(@special_chars, password)
    ]
    |> Enum.count(& &1)
  end

  @doc """
  Returns a human-readable label for a strength score.
  """
  def strength_label(score) do
    case score do
      0 -> "very weak"
      1 -> "weak"
      2 -> "fair"
      3 -> "strong"
      _ -> "very strong"
    end
  end

  @doc """
  Generates a list of human-readable policy hints for display in UI.
  """
  def policy_hints do
    min_length        = Application.fetch_env!(:password_policy, :min_length)
    require_uppercase = Application.fetch_env!(:password_policy, :require_uppercase)
    require_digit     = Application.fetch_env!(:password_policy, :require_digit)
    require_special   = Application.fetch_env!(:password_policy, :require_special)

    hints = ["At least #{min_length} characters"]
    hints = if require_uppercase, do: hints ++ ["At least one uppercase letter"], else: hints
    hints = if require_digit,     do: hints ++ ["At least one digit"], else: hints
    hints = if require_special,   do: hints ++ ["At least one special character"], else: hints

    hints
  end

  # --- Private validation checks ---

  defp check_length(errors, password, min) do
    if String.length(password) >= min do
      errors
    else
      ["must be at least #{min} characters" | errors]
    end
  end

  defp check_uppercase(errors, _password, false), do: errors

  defp check_uppercase(errors, password, true) do
    if Regex.match?(~r/[A-Z]/, password) do
      errors
    else
      ["must contain at least one uppercase letter" | errors]
    end
  end

  defp check_digit(errors, _password, false), do: errors

  defp check_digit(errors, password, true) do
    if Regex.match?(~r/[0-9]/, password) do
      errors
    else
      ["must contain at least one digit" | errors]
    end
  end

  defp check_special(errors, _password, false), do: errors

  defp check_special(errors, password, true) do
    if Regex.match?(@special_chars, password) do
      errors
    else
      ["must contain at least one special character" | errors]
    end
  end
end
```
