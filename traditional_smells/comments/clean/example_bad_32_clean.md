```elixir
defmodule MyApp.UserRegistration do
  @moduledoc """
  Handles new-user registration, email verification bootstrapping,
  and welcome notification dispatch for the MyApp platform.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{User, EmailVerification}
  alias MyApp.NotificationDispatcher
  alias Ecto.Multi

  require Logger

  @verification_token_bytes 32
  @verification_expiry_hours 48

  @doc """
  Returns `true` if the given email address is already taken.
  """
  def email_taken?(email) do
    normalized = String.downcase(String.trim(email))
    Repo.exists?(User, email: normalized)
  end


  # register/1
  #
  # Creates a new user account from the provided attribute map.
  #
  # Expected keys in `attrs`:
  #   :email       — required, must be unique and a valid email format
  #   :password    — required, minimum 8 characters
  #   :first_name  — required
  #   :last_name   — required
  #   :timezone    — optional, defaults to "UTC"
  #
  # Side effects on success:
  #   - Creates a User record with :unverified status.
  #   - Creates an EmailVerification record with a time-limited token.
  #   - Dispatches a :welcome_email notification via NotificationDispatcher.
  #
  # Returns:
  #   {:ok, %User{}} on success
  #   {:error, %Ecto.Changeset{}} on validation failure
  #   {:error, :email_taken} if the email is already registered
  def register(attrs) do
    email = attrs |> Map.get(:email, "") |> String.downcase() |> String.trim()

    if email_taken?(email) do
      {:error, :email_taken}
    else
      attrs_normalized = Map.put(attrs, :email, email)

      Multi.new()
      |> Multi.insert(:user, User.registration_changeset(%User{}, attrs_normalized))
      |> Multi.insert(:verification, fn %{user: user} ->
        build_verification(user)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user, verification: verification}} ->
          dispatch_welcome(user, verification)
          {:ok, user}

        {:error, :user, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies a user's email using the token sent during registration.

  Returns `{:ok, user}` on success, `{:error, :invalid_token}` if the token
  is missing or expired, or `{:error, :already_verified}` if the account is
  already active.
  """
  def verify_email(token) do
    cutoff = DateTime.add(DateTime.utc_now(), -@verification_expiry_hours * 3600, :second)

    case Repo.get_by(EmailVerification, token: token) do
      nil ->
        {:error, :invalid_token}

      %EmailVerification{inserted_at: ts} when ts < cutoff ->
        {:error, :invalid_token}

      %EmailVerification{user_id: user_id} ->
        user = Repo.get!(User, user_id)

        if user.status == :active do
          {:error, :already_verified}
        else
          user
          |> User.changeset(%{status: :active, email_verified_at: DateTime.utc_now()})
          |> Repo.update()
        end
    end
  end

  # --- Private helpers ---

  defp build_verification(user) do
    token =
      @verification_token_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    EmailVerification.changeset(%EmailVerification{}, %{
      user_id: user.id,
      token: token
    })
  end

  defp dispatch_welcome(user, verification) do
    notification = %{
      type: :welcome_email,
      subject: "Welcome to MyApp!",
      body: "Please verify your email: #{verification_url(verification.token)}",
      metadata: %{}
    }

    case NotificationDispatcher.dispatch(user, notification) do
      %{email: :ok} ->
        :ok

      result ->
        Logger.warning("Welcome email not fully delivered for user #{user.id}: #{inspect(result)}")
    end
  end

  defp verification_url(token) do
    MyAppWeb.Endpoint.url() <> "/verify-email?token=#{token}"
  end
end
```
