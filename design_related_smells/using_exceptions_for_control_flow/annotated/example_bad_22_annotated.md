# Annotated Example 22

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `CredentialValidator.verify/2` (library) and `AuthController.login/1` (client)
- **Affected function(s):** `CredentialValidator.verify/2`, `AuthController.login/1`
- **Short explanation:** `CredentialValidator.verify/2` raises typed exceptions for every foreseeable authentication failure (wrong password, unknown user, locked account) without offering a tuple-returning alternative. The client `AuthController.login/1` is consequently forced to use `try...rescue` to route users through normal login flows — treating ordinary business outcomes as exceptions.

```elixir
defmodule CredentialValidator do
  @moduledoc """
  Validates username/password pairs against stored account records.
  Used by authentication endpoints across the platform.
  """

  defmodule InvalidPasswordError do
    defexception [:message, :username]
  end

  defmodule UserNotFoundError do
    defexception [:message, :username]
  end

  defmodule AccountLockedError do
    defexception [:message, :username, :locked_until]
  end

  defmodule MissingFieldError do
    defexception [:message]
  end

  @max_failed_attempts 5

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because all predictable authentication outcomes
  # (unknown user, wrong password, locked account, missing fields) are surfaced
  # exclusively as exceptions. Clients cannot use pattern matching on a result
  # tuple; they must use try...rescue for ordinary login-flow control.
  def verify(username, password)
      when not is_binary(username) or not is_binary(password) do
    raise MissingFieldError,
      message: "Both username and password must be strings"
  end

  def verify(username, password) when byte_size(username) == 0 or byte_size(password) == 0 do
    raise MissingFieldError,
      message: "Username and password must not be blank"
  end

  def verify(username, password) do
    account = fetch_account(username)

    if is_nil(account) do
      raise UserNotFoundError,
        message: "No account registered for '#{username}'",
        username: username
    end

    if account.locked do
      raise AccountLockedError,
        message: "Account '#{username}' is locked due to too many failed attempts",
        username: username,
        locked_until: account.locked_until
    end

    unless valid_password?(password, account.password_hash) do
      record_failed_attempt(username, account.failed_attempts)

      raise InvalidPasswordError,
        message: "Invalid password for account '#{username}'",
        username: username
    end

    reset_failed_attempts(username)

    %{
      account_id: account.id,
      username: username,
      roles: account.roles,
      last_login: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  defp fetch_account("alice"),
    do: %{id: 1, password_hash: hash("secret"), roles: [:admin], locked: false, locked_until: nil, failed_attempts: 0}

  defp fetch_account("bob"),
    do: %{id: 2, password_hash: hash("pass123"), roles: [:user], locked: true, locked_until: ~U[2025-12-31 00:00:00Z], failed_attempts: 5}

  defp fetch_account(_), do: nil

  defp valid_password?(plain, hash), do: :crypto.hash(:sha256, plain) == hash
  defp hash(plain), do: :crypto.hash(:sha256, plain)

  defp record_failed_attempt(username, count) when count + 1 >= @max_failed_attempts do
    IO.puts("Locking account #{username}")
  end

  defp record_failed_attempt(username, _count) do
    IO.puts("Recording failed attempt for #{username}")
  end

  defp reset_failed_attempts(username) do
    IO.puts("Resetting failed attempts for #{username}")
  end
end

defmodule AuthController do
  @moduledoc """
  Handles HTTP authentication requests. Issues session tokens on success.
  """

  require Logger

  def login(%{"username" => username, "password" => password} = _params) do
    Logger.debug("Login attempt for user: #{username}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because the client must wrap every login
    # attempt in try...rescue to differentiate between successful login and
    # expected failures like wrong password or account lockout — none of which
    # are truly exceptional in an authentication context.
    try do
      account_info = CredentialValidator.verify(username, password)
      token = generate_session_token(account_info)

      Logger.info("Successful login for #{username}")

      {:ok,
       %{
         token: token,
         account_id: account_info.account_id,
         roles: account_info.roles
       }}
    rescue
      e in CredentialValidator.UserNotFoundError ->
        Logger.warning("Login failed — user not found: #{e.username}")
        {:error, :user_not_found}

      e in CredentialValidator.InvalidPasswordError ->
        Logger.warning("Login failed — wrong password for: #{e.username}")
        {:error, :invalid_credentials}

      e in CredentialValidator.AccountLockedError ->
        Logger.warning("Login blocked — account locked: #{e.username} until #{e.locked_until}")
        {:error, {:account_locked, e.locked_until}}

      e in CredentialValidator.MissingFieldError ->
        Logger.warning("Login rejected — missing fields: #{e.message}")
        {:error, :bad_request}
    end
    # VALIDATION: SMELL END
  end

  def login(_params) do
    {:error, :bad_request}
  end

  defp generate_session_token(%{account_id: id, username: username}) do
    raw = "#{id}:#{username}:#{System.system_time(:millisecond)}"
    Base.encode64(raw)
  end
end
```
