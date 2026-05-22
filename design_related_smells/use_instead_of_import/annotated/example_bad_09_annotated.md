# example_bad_09_annotated.md

## Metadata

- **Smell Name:** "Use" instead of "import"
- **Expected Smell Location:** `Accounts.UserRegistration` module, `use Accounts.ValidationHelpers` directive
- **Affected Function(s):** Module-level directive (affects the entire `Accounts.UserRegistration` module)
- **Short Explanation:** `Accounts.UserRegistration` uses `use Accounts.ValidationHelpers` only to access input-validation functions. The `__using__/1` macro additionally injects `import Accounts.PasswordUtils` into the caller, making password-hashing and strength-checking functions available in `UserRegistration` without any explicit declaration. Since only the validation functions are needed, `import Accounts.ValidationHelpers` would be the clear, non-invasive alternative.

## Code

```elixir
defmodule Accounts.PasswordUtils do
  @moduledoc """
  Password hashing, verification, and strength-assessment utilities.
  """

  @min_length 10
  @special_chars ~r/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?]/

  def hash(password) when is_binary(password) do
    :crypto.hash(:sha256, password) |> Base.encode64()
  end

  def verify(plain, hashed) when is_binary(plain) and is_binary(hashed) do
    Plug.Crypto.secure_compare(hash(plain), hashed)
  end

  def strength_score(password) when is_binary(password) do
    checks = [
      String.length(password) >= @min_length,
      String.match?(password, ~r/[A-Z]/),
      String.match?(password, ~r/[a-z]/),
      String.match?(password, ~r/[0-9]/),
      String.match?(password, @special_chars)
    ]

    Enum.count(checks, & &1)
  end

  def strong?(password), do: strength_score(password) >= 4
end

defmodule Accounts.ValidationHelpers do
  @moduledoc """
  Input validation helpers for user-facing data, shared across account
  modules via `use`.
  """

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @username_regex ~r/^[a-zA-Z0-9_]{3,32}$/

  defmacro __using__(_opts) do
    quote do
      import Accounts.PasswordUtils  # propagates password utilities into every caller

      def valid_email?(email) when is_binary(email) do
        String.match?(email, unquote(@email_regex))
      end

      def valid_email?(_), do: false

      def valid_username?(username) when is_binary(username) do
        String.match?(username, unquote(@username_regex))
      end

      def valid_username?(_), do: false

      def validate_required(params, fields) do
        missing = Enum.reject(fields, fn f -> Map.get(params, f) not in [nil, ""] end)
        if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
      end

      def normalize_email(email) when is_binary(email) do
        email |> String.downcase() |> String.trim()
      end
    end
  end
end

defmodule Accounts.UserRegistration do
  @moduledoc """
  Handles new user registration: parameter validation, password policy
  enforcement, account creation, and welcome notification queuing.
  """

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Accounts.ValidationHelpers` triggers
  # VALIDATION: `__using__/1`, which injects `import Accounts.PasswordUtils` into
  # VALIDATION: `UserRegistration`. Functions like `hash/1`, `verify/2`, and
  # VALIDATION: `strength_score/1` land in this module's namespace silently.
  # VALIDATION: The module only needs `valid_email?/1`, `valid_username?/1`,
  # VALIDATION: `validate_required/2`, and `normalize_email/1`. Using
  # VALIDATION: `import Accounts.ValidationHelpers` would be explicit and correct.
  use Accounts.ValidationHelpers
  # VALIDATION: SMELL END

  @required_fields [:email, :username, :password, :password_confirmation]

  def register(params) do
    with :ok              <- validate_required(params, @required_fields),
         :ok              <- check_passwords_match(params),
         :ok              <- check_password_policy(params.password),
         :ok              <- check_email(params.email),
         :ok              <- check_username(params.username),
         {:ok, user}      <- build_user(params) do
      {:ok, user}
    end
  end

  def build_user(params) do
    user = %{
      id:              new_id(),
      email:           normalize_email(params.email),
      username:        params.username,
      password_hash:   hash(params.password),
      role:            :member,
      verified:        false,
      verification_token: verification_token(),
      created_at:      DateTime.utc_now(),
      updated_at:      DateTime.utc_now()
    }

    {:ok, user}
  end

  def resend_verification(user) do
    if user.verified do
      {:error, :already_verified}
    else
      {:ok, %{user | verification_token: verification_token(), updated_at: DateTime.utc_now()}}
    end
  end

  def complete_verification(user, token) do
    if user.verification_token == token do
      {:ok, %{user | verified: true, verification_token: nil, updated_at: DateTime.utc_now()}}
    else
      {:error, :invalid_token}
    end
  end

  defp check_passwords_match(%{password: p, password_confirmation: pc}) when p == pc, do: :ok
  defp check_passwords_match(_), do: {:error, :passwords_do_not_match}

  defp check_password_policy(password) do
    if strong?(password), do: :ok, else: {:error, :password_too_weak}
  end

  defp check_email(email) do
    if valid_email?(email), do: :ok, else: {:error, :invalid_email}
  end

  defp check_username(username) do
    if valid_username?(username), do: :ok, else: {:error, :invalid_username}
  end

  defp new_id, do: :erlang.unique_integer([:positive, :monotonic])

  defp verification_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
```
