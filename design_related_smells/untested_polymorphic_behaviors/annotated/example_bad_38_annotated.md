## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `normalize_username/1` — the `to_string(username)` call
- **Affected function(s):** `Auth.CredentialNormalizer.normalize_username/1`
- **Short explanation:** `to_string/1` uses the `String.Chars` protocol. The function accepts any `username` value without a guard clause, so passing a `Map`, `Tuple`, or struct that does not implement `String.Chars` causes a `Protocol.UndefinedError`. Even types that do implement it (e.g., integers) produce meaningless normalized usernames.

```elixir
defmodule Auth.CredentialNormalizer do
  @moduledoc """
  Normalizes and sanitizes credential fields before storage and comparison.
  Used during registration, login, and profile-update flows.
  """

  @username_max_length 64
  @username_allowed_pattern ~r/^[a-z0-9._-]+$/
  @email_domains_blocklist ~w(mailinator.com guerrillamail.com trashmail.com)

  def normalize_credentials(%{username: username, email: email} = params) do
    with {:ok, clean_username} <- normalize_username(username),
         {:ok, clean_email} <- normalize_email(email) do
      {:ok, %{params | username: clean_username, email: clean_email}}
    end
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `to_string(username)` relies on the `String.Chars`
  # VALIDATION: protocol. No guard clause or pattern match restricts `username` to types
  # VALIDATION: that implement it. Passing a Map (e.g., a nested params struct), Tuple,
  # VALIDATION: or PID crashes with `Protocol.UndefinedError`. Even passing an integer
  # VALIDATION: succeeds silently and produces a normalized "username" like "42", which
  # VALIDATION: almost certainly makes no semantic sense in this context.
  def normalize_username(username) do
    normalized =
      username
      |> to_string()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/\s+/, "_")
      |> String.slice(0, @username_max_length)

    if String.match?(normalized, @username_allowed_pattern) do
      {:ok, normalized}
    else
      {:error, {:invalid_username, normalized}}
    end
  end
  # VALIDATION: SMELL END

  def normalize_email(email) when is_binary(email) do
    normalized = email |> String.downcase() |> String.trim()

    case String.split(normalized, "@") do
      [_local, domain] when domain in @email_domains_blocklist ->
        {:error, :disposable_email_domain}

      [_local, _domain] ->
        {:ok, normalized}

      _ ->
        {:error, :malformed_email}
    end
  end

  def normalize_email(_), do: {:error, :email_must_be_string}

  def validate_password_strength(password) when is_binary(password) do
    checks = [
      {String.length(password) >= 8, :too_short},
      {String.match?(password, ~r/[A-Z]/), :missing_uppercase},
      {String.match?(password, ~r/[0-9]/), :missing_digit},
      {String.match?(password, ~r/[^a-zA-Z0-9]/), :missing_special_char}
    ]

    failed = for {false, reason} <- checks, do: reason

    case failed do
      [] -> :ok
      reasons -> {:error, {:weak_password, reasons}}
    end
  end

  def validate_password_strength(_), do: {:error, :password_must_be_string}

  def hash_password(password) when is_binary(password) do
    Bcrypt.hash_pwd_salt(password)
  end

  def verify_password(password, hash) when is_binary(password) and is_binary(hash) do
    Bcrypt.verify_pass(password, hash)
  end

  def obfuscate_email(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] ->
        visible = String.slice(local, 0, 2)
        stars = String.duplicate("*", max(0, String.length(local) - 2))
        "#{visible}#{stars}@#{domain}"

      _ ->
        email
    end
  end
end
```
