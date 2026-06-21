# File: `example_good_235.md`

```elixir
defmodule Accounts.PasswordPolicy do
  @moduledoc """
  Enforces configurable password strength requirements at the domain boundary.

  A policy is a plain struct describing the active constraints. Validation
  is a pure function that returns a list of human-readable violations so
  callers can display all failures at once rather than one at a time.
  """

  @enforce_keys [:min_length]
  defstruct [
    :min_length,
    max_length: 128,
    require_uppercase: true,
    require_lowercase: true,
    require_digit: true,
    require_special: true,
    min_unique_chars: 6,
    disallowed_patterns: []
  ]

  @type t :: %__MODULE__{
          min_length: pos_integer(),
          max_length: pos_integer(),
          require_uppercase: boolean(),
          require_lowercase: boolean(),
          require_digit: boolean(),
          require_special: boolean(),
          min_unique_chars: non_neg_integer(),
          disallowed_patterns: [Regex.t()]
        }

  @type violation :: String.t()

  @doc """
  Validates `password` against `policy`, returning `{:ok, password}` when
  all constraints pass or `{:error, violations}` with a non-empty list of
  human-readable failure messages.
  """
  @spec validate(String.t(), t()) :: {:ok, String.t()} | {:error, [violation()]}
  def validate(password, %__MODULE__{} = policy) when is_binary(password) do
    violations = collect_violations(password, policy)

    case violations do
      [] -> {:ok, password}
      _ -> {:error, violations}
    end
  end

  @doc """
  Returns the default policy suitable for most consumer-facing applications.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{min_length: 10}
  end

  @doc """
  Returns a strict policy for high-security contexts such as admin accounts.
  """
  @spec strict() :: t()
  def strict do
    %__MODULE__{
      min_length: 16,
      require_uppercase: true,
      require_lowercase: true,
      require_digit: true,
      require_special: true,
      min_unique_chars: 10,
      disallowed_patterns: [~r/(.)\1{2,}/]
    }
  end

  @doc """
  Returns `true` when `password` fully satisfies `policy`.
  """
  @spec valid?(String.t(), t()) :: boolean()
  def valid?(password, %__MODULE__{} = policy) when is_binary(password) do
    collect_violations(password, policy) == []
  end

  defp collect_violations(password, policy) do
    []
    |> check_min_length(password, policy)
    |> check_max_length(password, policy)
    |> check_uppercase(password, policy)
    |> check_lowercase(password, policy)
    |> check_digit(password, policy)
    |> check_special(password, policy)
    |> check_unique_chars(password, policy)
    |> check_disallowed_patterns(password, policy)
    |> Enum.reverse()
  end

  defp check_min_length(violations, pw, %{min_length: min}) do
    if String.length(pw) < min do
      ["must be at least #{min} characters" | violations]
    else
      violations
    end
  end

  defp check_max_length(violations, pw, %{max_length: max}) do
    if String.length(pw) > max do
      ["must be no more than #{max} characters" | violations]
    else
      violations
    end
  end

  defp check_uppercase(violations, pw, %{require_uppercase: true}) do
    if Regex.match?(~r/[A-Z]/, pw), do: violations, else: ["must contain at least one uppercase letter" | violations]
  end

  defp check_uppercase(violations, _pw, _policy), do: violations

  defp check_lowercase(violations, pw, %{require_lowercase: true}) do
    if Regex.match?(~r/[a-z]/, pw), do: violations, else: ["must contain at least one lowercase letter" | violations]
  end

  defp check_lowercase(violations, _pw, _policy), do: violations

  defp check_digit(violations, pw, %{require_digit: true}) do
    if Regex.match?(~r/[0-9]/, pw), do: violations, else: ["must contain at least one digit" | violations]
  end

  defp check_digit(violations, _pw, _policy), do: violations

  defp check_special(violations, pw, %{require_special: true}) do
    if Regex.match?(~r/[^a-zA-Z0-9]/, pw), do: violations, else: ["must contain at least one special character" | violations]
  end

  defp check_special(violations, _pw, _policy), do: violations

  defp check_unique_chars(violations, pw, %{min_unique_chars: min}) when min > 0 do
    unique = pw |> String.graphemes() |> Enum.uniq() |> length()
    if unique < min do
      ["must contain at least #{min} distinct characters" | violations]
    else
      violations
    end
  end

  defp check_unique_chars(violations, _pw, _policy), do: violations

  defp check_disallowed_patterns(violations, pw, %{disallowed_patterns: patterns}) do
    Enum.reduce(patterns, violations, fn pattern, acc ->
      if Regex.match?(pattern, pw) do
        ["contains a disallowed character pattern" | acc]
      else
        acc
      end
    end)
  end
end
```
