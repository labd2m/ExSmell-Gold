```elixir
defmodule UserManagement.Registrar do
  @moduledoc """
  Handles new user registration, including validation, persistence,
  email verification, and initial preference setup.
  """

  alias UserManagement.{User, VerificationToken, UserPreference, AuditEntry, Repo}
  alias Integrations.Mailer
  require Logger

  @min_password_length 10
  @verification_token_ttl_hours 48
  @default_preferences %{
    email_marketing: false,
    weekly_digest: true,
    product_updates: true,
    sms_alerts: false
  }

  def register(%{email: email, password: password, full_name: full_name} = params) do
    email_normalized = email |> String.trim() |> String.downcase()
    Logger.info("Registering new user email=#{email_normalized}")

    # --- Check for existing account ---
    if Repo.get_by(User, email: email_normalized) do
      {:error, :email_already_taken}
    else
      # --- Password strength validation ---
      password_errors =
        []
        |> then(fn errs ->
          if String.length(password) < @min_password_length,
            do: [:too_short | errs], else: errs
        end)
        |> then(fn errs ->
          if String.match?(password, ~r/[A-Z]/), do: errs, else: [:no_uppercase | errs]
        end)
        |> then(fn errs ->
          if String.match?(password, ~r/[0-9]/), do: errs, else: [:no_digit | errs]
        end)
        |> then(fn errs ->
          if String.match?(password, ~r/[^a-zA-Z0-9]/), do: errs, else: [:no_special_char | errs]
        end)

      if password_errors != [] do
        {:error, {:weak_password, password_errors}}
      else
        password_hash = Bcrypt.hash_pwd_salt(password)

        user_attrs = %{
          email: email_normalized,
          password_hash: password_hash,
          full_name: String.trim(full_name),
          username: Map.get(params, :username, email_normalized |> String.split("@") |> hd()),
          role: :member,
          status: :pending_verification,
          registered_ip: Map.get(params, :ip_address),
          registered_at: DateTime.utc_now()
        }

        case Repo.insert(User.changeset(%User{}, user_attrs)) do
          {:ok, user} ->
            # --- Generate email verification token ---
            raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
            expires_at = DateTime.add(DateTime.utc_now(), @verification_token_ttl_hours * 3600, :second)

            Repo.insert!(%VerificationToken{
              user_id: user.id,
              token: raw_token,
              expires_at: expires_at,
              purpose: :email_verification
            })

            # --- Send welcome and verification email ---
            case Mailer.send_verification(%{
                   to: user.email,
                   full_name: user.full_name,
                   verification_url: build_verification_url(raw_token)
                 }) do
              {:ok, _} ->
                Logger.info("Verification email sent to #{user.email}")

              {:error, reason} ->
                Logger.warning("Verification email failed for #{user.email}: #{inspect(reason)}")
            end

            # --- Seed default preferences ---
            Enum.each(@default_preferences, fn {key, value} ->
              Repo.insert!(%UserPreference{
                user_id: user.id,
                key: Atom.to_string(key),
                value: to_string(value)
              })
            end)

            # --- Record audit entry ---
            Repo.insert!(%AuditEntry{
              user_id: user.id,
              action: "user_registered",
              actor_id: user.id,
              metadata: %{
                ip_address: Map.get(params, :ip_address),
                user_agent: Map.get(params, :user_agent)
              },
              occurred_at: DateTime.utc_now()
            })

            Logger.info("User #{user.id} registered successfully")
            {:ok, user}

          {:error, changeset} ->
            Logger.error("User insert failed: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
      end
    end
  end

  defp build_verification_url(token) do
    base = Application.get_env(:user_management, :base_url, "https://app.example.com")
    "#{base}/verify?token=#{token}"
  end
end
```
