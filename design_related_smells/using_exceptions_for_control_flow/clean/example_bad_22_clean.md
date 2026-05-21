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
