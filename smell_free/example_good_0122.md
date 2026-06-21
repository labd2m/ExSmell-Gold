```elixir
defmodule MyApp.Accounts.PasswordPolicy do
  @moduledoc """
  Validates and hashes passwords according to a configurable policy.
  Policy parameters are accepted as options at the call site, keeping
  this module reusable across different user classes (customers, admins)
  that enforce different requirements.

  Hashing is delegated to `Bcrypt` from the `bcrypt_elixir` package.
  No policy defaults are read from the Application environment.
  """

  @type policy :: %{
          optional(:min_length) => pos_integer(),
          optional(:max_length) => pos_integer(),
          optional(:require_digit) => boolean(),
          optional(:require_uppercase) => boolean(),
          optional(:require_symbol) => boolean()
        }

  @type violation ::
          :too_short
          | :too_long
          | :missing_digit
          | :missing_uppercase
          | :missing_symbol

  @doc """
  Validates `password` against `policy` and returns a list of violations.
  An empty list means the password satisfies every constraint.

  ## Options

    * `:min_length` - minimum character count (default: `8`)
    * `:max_length` - maximum character count (default: `128`)
    * `:require_digit` - must contain at least one digit (default: `true`)
    * `:require_uppercase` - must contain at least one uppercase letter (default: `false`)
    * `:require_symbol` - must contain at least one symbol character (default: `false`)
  """
  @spec validate(String.t(), policy()) :: [violation()]
  def validate(password, policy \\ %{}) when is_binary(password) do
    [
      &check_min_length/2,
      &check_max_length/2,
      &check_digit/2,
      &check_uppercase/2,
      &check_symbol/2
    ]
    |> Enum.flat_map(fn check -> check.(password, policy) end)
  end

  @doc """
  Hashes a password using Bcrypt and returns the hash string.
  Always uses 12 rounds regardless of caller options.
  """
  @spec hash(String.t()) :: String.t()
  def hash(password) when is_binary(password), do: Bcrypt.hash_pwd_salt(password)

  @doc """
  Verifies that `password` matches a previously generated `hash`.
  """
  @spec verify(String.t(), String.t()) :: boolean()
  def verify(password, hash)
      when is_binary(password) and is_binary(hash),
      do: Bcrypt.verify_pass(password, hash)

  @doc """
  Returns `{:ok, hash}` when the password passes the given policy, or
  `{:error, violations}` listing every constraint that was not met.
  """
  @spec validate_and_hash(String.t(), policy()) ::
          {:ok, String.t()} | {:error, [violation()]}
  def validate_and_hash(password, policy \\ %{}) when is_binary(password) do
    case validate(password, policy) do
      [] -> {:ok, hash(password)}
      violations -> {:error, violations}
    end
  end

  @spec check_min_length(String.t(), policy()) :: [violation()]
  defp check_min_length(pw, policy) do
    min = Map.get(policy, :min_length, 8)
    if String.length(pw) < min, do: [:too_short], else: []
  end

  @spec check_max_length(String.t(), policy()) :: [violation()]
  defp check_max_length(pw, policy) do
    max = Map.get(policy, :max_length, 128)
    if String.length(pw) > max, do: [:too_long], else: []
  end

  @spec check_digit(String.t(), policy()) :: [violation()]
  defp check_digit(pw, policy) do
    if Map.get(policy, :require_digit, true) and not String.match?(pw, ~r/[0-9]/),
      do: [:missing_digit],
      else: []
  end

  @spec check_uppercase(String.t(), policy()) :: [violation()]
  defp check_uppercase(pw, policy) do
    if Map.get(policy, :require_uppercase, false) and not String.match?(pw, ~r/[A-Z]/),
      do: [:missing_uppercase],
      else: []
  end

  @spec check_symbol(String.t(), policy()) :: [violation()]
  defp check_symbol(pw, policy) do
    if Map.get(policy, :require_symbol, false) and
         not String.match?(pw, ~r/[!@#$%^&*()\-_=+\[\]{}|;:',.<>?\/]/),
       do: [:missing_symbol],
       else: []
  end
end
```
