```elixir
defmodule Auth.PasswordPolicy do
  @moduledoc """
  Validates plaintext passwords against a configurable set of strength rules.
  Each rule is an independent check returning a labelled result, allowing
  callers to surface granular feedback rather than a single pass/fail.
  """

  @type rule_result :: %{rule: atom(), passed: boolean(), message: String.t()}
  @type policy_opts :: [
          min_length: pos_integer(),
          require_uppercase: boolean(),
          require_digit: boolean(),
          require_symbol: boolean(),
          max_length: pos_integer()
        ]

  @default_opts [
    min_length: 12,
    require_uppercase: true,
    require_digit: true,
    require_symbol: true,
    max_length: 128
  ]

  @spec validate(String.t(), policy_opts()) ::
          {:ok, String.t()} | {:error, [rule_result()]}
  def validate(password, opts \\ []) when is_binary(password) do
    effective = Keyword.merge(@default_opts, opts)
    failures = run_rules(password, effective) |> Enum.reject(& &1.passed)

    case failures do
      [] -> {:ok, password}
      _ -> {:error, failures}
    end
  end

  @spec check(String.t(), policy_opts()) :: [rule_result()]
  def check(password, opts \\ []) when is_binary(password) do
    run_rules(password, Keyword.merge(@default_opts, opts))
  end

  @spec run_rules(String.t(), policy_opts()) :: [rule_result()]
  defp run_rules(password, opts) do
    [
      check_min_length(password, opts[:min_length]),
      check_max_length(password, opts[:max_length]),
      check_uppercase(password, opts[:require_uppercase]),
      check_digit(password, opts[:require_digit]),
      check_symbol(password, opts[:require_symbol])
    ]
  end

  @spec check_min_length(String.t(), pos_integer()) :: rule_result()
  defp check_min_length(password, min) do
    passed = String.length(password) >= min
    %{rule: :min_length, passed: passed, message: "Must be at least #{min} characters"}
  end

  @spec check_max_length(String.t(), pos_integer()) :: rule_result()
  defp check_max_length(password, max) do
    passed = String.length(password) <= max
    %{rule: :max_length, passed: passed, message: "Must be at most #{max} characters"}
  end

  @spec check_uppercase(String.t(), boolean()) :: rule_result()
  defp check_uppercase(_password, false) do
    %{rule: :uppercase, passed: true, message: "Must contain an uppercase letter"}
  end

  defp check_uppercase(password, true) do
    passed = Regex.match?(~r/[A-Z]/, password)
    %{rule: :uppercase, passed: passed, message: "Must contain at least one uppercase letter"}
  end

  @spec check_digit(String.t(), boolean()) :: rule_result()
  defp check_digit(_password, false) do
    %{rule: :digit, passed: true, message: "Must contain a digit"}
  end

  defp check_digit(password, true) do
    passed = Regex.match?(~r/[0-9]/, password)
    %{rule: :digit, passed: passed, message: "Must contain at least one digit"}
  end

  @spec check_symbol(String.t(), boolean()) :: rule_result()
  defp check_symbol(_password, false) do
    %{rule: :symbol, passed: true, message: "Must contain a symbol"}
  end

  defp check_symbol(password, true) do
    passed = Regex.match?(~r/[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/, password)
    %{rule: :symbol, passed: passed, message: "Must contain at least one symbol"}
  end
end
```
