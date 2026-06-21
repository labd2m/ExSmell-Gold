```elixir
defmodule Accounts.PasswordPolicy do
  @moduledoc """
  Enforces password complexity rules before hashing. Rules are composed
  from a list of named validators, each returning `:ok` or a structured
  error. The module exposes both a full validation pass that collects all
  violations and a strict pass that returns on the first failure, useful
  for real-time field feedback versus final form submission.
  """

  @type password :: String.t()
  @type violation :: %{rule: atom(), message: String.t()}
  @type validation_result :: :ok | {:error, [violation()]}

  @min_length 12
  @max_length 128
  @min_unique_chars 6

  @doc """
  Validates `password` against all rules and collects every violation.
  Returns `:ok` when the password satisfies all rules.
  """
  @spec validate(password()) :: validation_result()
  def validate(password) when is_binary(password) do
    violations =
      all_rules()
      |> Enum.flat_map(fn {rule, fun} ->
        case fun.(password) do
          :ok -> []
          {:error, msg} -> [%{rule: rule, message: msg}]
        end
      end)

    if Enum.empty?(violations), do: :ok, else: {:error, violations}
  end

  @doc """
  Validates `password` and returns on the first violation found.
  Useful for incremental feedback during user input.
  """
  @spec validate_first(password()) :: :ok | {:error, violation()}
  def validate_first(password) when is_binary(password) do
    result =
      Enum.find_value(all_rules(), fn {rule, fun} ->
        case fun.(password) do
          :ok -> nil
          {:error, msg} -> %{rule: rule, message: msg}
        end
      end)

    case result do
      nil -> :ok
      violation -> {:error, violation}
    end
  end

  @doc "Returns the list of active rule names."
  @spec rule_names() :: [atom()]
  def rule_names, do: Enum.map(all_rules(), fn {name, _} -> name end)

  defp all_rules do
    [
      {:min_length, &check_min_length/1},
      {:max_length, &check_max_length/1},
      {:requires_uppercase, &check_uppercase/1},
      {:requires_lowercase, &check_lowercase/1},
      {:requires_digit, &check_digit/1},
      {:requires_special, &check_special/1},
      {:unique_chars, &check_unique_chars/1}
    ]
  end

  defp check_min_length(pw) do
    if String.length(pw) >= @min_length, do: :ok,
      else: {:error, "must be at least #{@min_length} characters"}
  end

  defp check_max_length(pw) do
    if String.length(pw) <= @max_length, do: :ok,
      else: {:error, "must not exceed #{@max_length} characters"}
  end

  defp check_uppercase(pw) do
    if String.match?(pw, ~r/[A-Z]/), do: :ok,
      else: {:error, "must contain at least one uppercase letter"}
  end

  defp check_lowercase(pw) do
    if String.match?(pw, ~r/[a-z]/), do: :ok,
      else: {:error, "must contain at least one lowercase letter"}
  end

  defp check_digit(pw) do
    if String.match?(pw, ~r/[0-9]/), do: :ok,
      else: {:error, "must contain at least one digit"}
  end

  defp check_special(pw) do
    if String.match?(pw, ~r/[^a-zA-Z0-9]/), do: :ok,
      else: {:error, "must contain at least one special character"}
  end

  defp check_unique_chars(pw) do
    unique = pw |> String.graphemes() |> MapSet.new() |> MapSet.size()
    if unique >= @min_unique_chars, do: :ok,
      else: {:error, "must contain at least #{@min_unique_chars} distinct characters"}
  end
end
```
