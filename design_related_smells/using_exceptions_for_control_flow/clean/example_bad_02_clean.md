```elixir
defmodule Auth.User do
  @moduledoc "Represents an application user stored in the database."

  @enforce_keys [:id, :email, :password_hash, :status, :failed_attempts]
  defstruct [:id, :email, :password_hash, :status, :failed_attempts, :locked_until]

  @type status :: :active | :inactive | :locked

  def locked?(%__MODULE__{status: :locked}), do: true
  def locked?(%__MODULE__{locked_until: nil}), do: false

  def locked?(%__MODULE__{locked_until: locked_until}) do
    DateTime.compare(locked_until, DateTime.utc_now()) == :gt
  end
end

defmodule Auth.PasswordHasher do
  @moduledoc "Thin wrapper around the bcrypt hashing library."

  def verify(plain, hash) do
    # Simulates bcrypt comparison
    :crypto.hash(:sha256, plain) == Base.decode64!(hash)
  rescue
    _ -> false
  end
end

defmodule Auth.UserRepository do
  @moduledoc "Loads users from the persistence layer."

  alias Auth.User

  @users %{
    "alice@example.com" => %User{
      id: "u_01",
      email: "alice@example.com",
      password_hash: Base.encode64(:crypto.hash(:sha256, "secret")),
      status: :active,
      failed_attempts: 0
    }
  }

  def find_by_email(email), do: Map.fetch(@users, email)

  def increment_failed_attempts(%User{} = user),
    do: {:ok, %{user | failed_attempts: user.failed_attempts + 1}}

  def reset_failed_attempts(%User{} = user),
    do: {:ok, %{user | failed_attempts: 0}}
end

defmodule Auth.CredentialVerifier do
  @moduledoc """
  Verifies user credentials against the stored password hash.
  Used by the session manager during the login flow.
  """

  alias Auth.{PasswordHasher, User, UserRepository}

  @max_attempts 5

  def verify(email, password) when is_binary(email) and is_binary(password) do
    case UserRepository.find_by_email(email) do
      :error ->
        raise RuntimeError, message: "No account found for '#{email}'"

      {:ok, user} ->
        if User.locked?(user) do
          raise RuntimeError,
            message: "Account is locked due to too many failed attempts"
        end

        if user.failed_attempts >= @max_attempts do
          raise RuntimeError,
            message: "Account is temporarily suspended after #{@max_attempts} failed logins"
        end

        unless PasswordHasher.verify(password, user.password_hash) do
          UserRepository.increment_failed_attempts(user)

          raise RuntimeError, message: "Invalid password for account '#{email}'"
        end

        UserRepository.reset_failed_attempts(user)
        user
    end
  end
end

defmodule Auth.SessionManager do
  @moduledoc """
  Creates and invalidates user sessions after successful credential verification.
  """

  require Logger

  alias Auth.CredentialVerifier

  defmodule Session do
    defstruct [:id, :user_id, :token, :expires_at, :created_at]
  end

  def create_session(email, password) do
    # Client forced to use try/rescue because CredentialVerifier.verify/2
    # raises on every failure branch instead of returning {:error, reason}.
    try do
      user = CredentialVerifier.verify(email, password)

      session = %Session{
        id: "sess_#{:rand.uniform(999_999)}",
        user_id: user.id,
        token: Base.url_encode64(:crypto.strong_rand_bytes(32)),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        created_at: DateTime.utc_now()
      }

      Logger.info("Session created for user=#{user.id}")
      {:ok, session}
    rescue
      e in RuntimeError ->
        Logger.warning("Login failed for email=#{email}: #{e.message}")
        {:error, e.message}
    end
  end

  def invalidate_session(%Session{id: id, user_id: user_id}) do
    Logger.info("Session #{id} invalidated for user=#{user_id}")
    :ok
  end

  def refresh_session(%Session{} = session) do
    if DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt do
      {:error, "session_expired"}
    else
      updated = %{session | expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)}
      {:ok, updated}
    end
  end
end
```
