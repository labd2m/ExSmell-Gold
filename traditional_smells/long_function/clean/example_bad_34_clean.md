```elixir
defmodule Accounts.RegistrationService do
  @moduledoc """
  Handles new user registration, including validation,
  profile setup, plan assignment, and onboarding.
  """

  require Logger

  alias Accounts.{User, Profile, EmailVerification, Plan, OnboardingTask, Mailer, PushNotifier}
  alias Comeonin.Argon2

  @default_plan         :starter
  @verification_ttl_hrs 48
  @min_password_length  10

  def register(attrs) do
    # 1. Normalise inputs
    email      = attrs |> Map.get("email", "")    |> String.trim() |> String.downcase()
    username   = attrs |> Map.get("username", "") |> String.trim()
    password   = Map.get(attrs, "password", "")
    first_name = attrs |> Map.get("first_name", "") |> String.trim()
    last_name  = attrs |> Map.get("last_name", "")  |> String.trim()
    plan_key   = attrs |> Map.get("plan", "starter") |> String.to_existing_atom()

    # 2. Basic field presence validation
    cond do
      email == "" ->
        {:error, %{email: ["can't be blank"]}}

      username == "" ->
        {:error, %{username: ["can't be blank"]}}

      first_name == "" or last_name == "" ->
        {:error, %{name: ["first and last name required"]}}

      String.length(password) < @min_password_length ->
        {:error, %{password: ["must be at least #{@min_password_length} characters"]}}

      not String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) ->
        {:error, %{email: ["is not a valid email address"]}}

      true ->
        # 3. Check e-mail uniqueness
        case User.find_by_email(email) do
          %User{} ->
            {:error, %{email: ["has already been taken"]}}

          nil ->
            # 4. Check username uniqueness
            case User.find_by_username(username) do
              %User{} ->
                {:error, %{username: ["has already been taken"]}}

              nil ->
                # 5. Hash the password
                password_hash = Argon2.hash_pwd_salt(password)

                # 6. Resolve plan
                plan =
                  case Plan.find_by_key(plan_key) do
                    nil   -> Plan.find_by_key(@default_plan)
                    found -> found
                  end

                # 7. Persist the user
                user_attrs = %{
                  email:         email,
                  username:      username,
                  password_hash: password_hash,
                  first_name:    first_name,
                  last_name:     last_name,
                  plan_id:       plan.id,
                  role:          :member,
                  active:        true,
                  inserted_at:   DateTime.utc_now()
                }

                case User.insert(user_attrs) do
                  {:error, reason} ->
                    Logger.error("User insert failed: #{inspect(reason)}")
                    {:error, :persistence_failed}

                  {:ok, user} ->
                    # 8. Create profile record
                    Profile.insert(%{
                      user_id:    user.id,
                      avatar_url: nil,
                      bio:        "",
                      timezone:   "UTC"
                    })

                    # 9. Generate and send e-mail verification
                    token      = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
                    expires_at = DateTime.add(DateTime.utc_now(), @verification_ttl_hrs * 3600, :second)

                    EmailVerification.insert(%{
                      user_id:    user.id,
                      token:      token,
                      expires_at: expires_at
                    })

                    verify_url  = "https://app.example.com/verify/#{token}"
                    email_body  = """
                    Hi #{first_name},

                    Welcome! Please verify your email address by clicking the link below:
                    #{verify_url}

                    This link expires in #{@verification_ttl_hrs} hours.

                    – The Team
                    """

                    case Mailer.send_email(email, "Verify your email", email_body) do
                      {:ok, _}         -> :ok
                      {:error, reason} ->
                        Logger.warning("Verification email failed for #{user.id}: #{inspect(reason)}")
                    end

                    # 10. Seed onboarding tasks
                    default_tasks = [
                      "Complete your profile",
                      "Connect your first integration",
                      "Invite a team member",
                      "Create your first project"
                    ]

                    Enum.each(default_tasks, fn task_title ->
                      OnboardingTask.insert(%{user_id: user.id, title: task_title, completed: false})
                    end)

                    # 11. Send welcome push notification
                    if user.push_token do
                      PushNotifier.notify(%{
                        token: user.push_token,
                        title: "Welcome to Example!",
                        body:  "Your account is ready. Let's get started 🚀"
                      })
                    end

                    Logger.info("New user registered: #{user.id} (#{email})")
                    {:ok, user}
                end
            end
        end
    end
  end
end
```
