```elixir
defmodule Auth.PasswordPolicy do
  @moduledoc """
  Enforces password strength rules for user registration and
  password-reset flows. Rules are aligned with NIST SP 800-63B.
  """

  @min_length 12
  @max_length 128

  defmacro validate_strength(password) do
    quote do
      pwd = unquote(password)
      cond do
        String.length(pwd) < unquote(@min_length) ->
          {:error, "Password must be at least #{unquote(@min_length)} characters long"}

        String.length(pwd) > unquote(@max_length) ->
          {:error, "Password must not exceed #{unquote(@max_length)} characters"}

        not String.match?(pwd, ~r/[A-Z]/) ->
          {:error, "Password must contain at least one uppercase letter"}

        not String.match?(pwd, ~r/[a-z]/) ->
          {:error, "Password must contain at least one lowercase letter"}

        not String.match?(pwd, ~r/[0-9]/) ->
          {:error, "Password must contain at least one digit"}

        not String.match?(pwd, ~r/[!@#$%^&*(),.?":{}|<>]/) ->
          {:error, "Password must contain at least one special character"}

        true ->
          :ok
      end
    end
  end

  def check_reuse(new_password, hashed_history) do
    Enum.any?(hashed_history, fn old_hash ->
      Bcrypt.verify_pass(new_password, old_hash)
    end)
  end

  def check_common(password) do
    common = ~w(password 123456789 qwertyuiop letmein welcome)
    downcased = String.downcase(password)
    if Enum.member?(common, downcased) do
      {:error, "Password is too common"}
    else
      :ok
    end
  end

  def apply_all(password, hashed_history \\ []) do
    require Auth.PasswordPolicy

    with :ok <- Auth.PasswordPolicy.validate_strength(password),
         :ok <- check_common(password) do
      if check_reuse(password, hashed_history) do
        {:error, "Password was recently used"}
      else
        :ok
      end
    end
  end

  def score(password) do
    length_score = min(String.length(password) * 2, 40)

    variety_score =
      [~r/[A-Z]/, ~r/[a-z]/, ~r/[0-9]/, ~r/[!@#$%^&*()]/]
      |> Enum.count(&String.match?(password, &1))
      |> Kernel.*(15)

    length_score + variety_score
  end

  def strength_label(password) do
    case score(password) do
      s when s < 40 -> :weak
      s when s < 70 -> :moderate
      _ -> :strong
    end
  end

  def generate_hint(failed_result) do
    case failed_result do
      {:error, msg} -> "Hint: #{msg}"
      :ok -> "Password is acceptable"
    end
  end
end
```
