# Example Bad 09 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `UserManagement.ConsentTracker` (module definition)
- **Affected Function(s)**: entire `UserManagement.ConsentTracker` module
- **Explanation**: `UserManagement.ConsentTracker` was defined speculatively to manage
  GDPR consent records and audit trails per user. The main module
  `UserManagement.AccountService` never calls any function from `ConsentTracker`;
  consent is simply stored as a boolean field on the user record. The entire module
  is dead code that exists only as future-proofing that was never activated.

## Code

```elixir
defmodule UserManagement.AccountService do
  @moduledoc """
  Manages user account lifecycle: creation, updates, deactivation, and
  password management. Core service for the identity and access layer.
  """

  alias UserManagement.{User, PasswordHash, EmailVerification}
  alias UserManagement.Repo
  alias Notifications.Mailer

  @min_password_length  8
  @verification_ttl_hrs 48

  def register(attrs) do
    with :ok <- validate_email_format(attrs.email),
         :ok <- validate_password_strength(attrs.password),
         {:ok, hashed_pw} <- PasswordHash.hash(attrs.password) do
      user_attrs = %{
        email:           attrs.email,
        name:            attrs.name,
        hashed_password: hashed_pw,
        role:            :user,
        status:          :pending_verification,
        consented:       Map.get(attrs, :consented, false),
        registered_at:   DateTime.utc_now()
      }

      case User.changeset(%User{}, user_attrs) |> Repo.insert() do
        {:ok, user} ->
          token = EmailVerification.generate_token(user.id)
          Mailer.send_verification(user.email, token)
          {:ok, user}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def verify_email(token) do
    case EmailVerification.validate_token(token) do
      {:ok, user_id} ->
        user = Repo.get!(User, user_id)

        user
        |> User.changeset(%{status: :active, email_verified_at: DateTime.utc_now()})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_profile(user_id, attrs) do
    user          = Repo.get!(User, user_id)
    allowed_keys  = [:name, :phone, :avatar_url, :timezone]
    filtered      = Map.take(attrs, allowed_keys)

    user
    |> User.changeset(filtered)
    |> Repo.update()
  end

  def change_password(user_id, current_password, new_password) do
    user = Repo.get!(User, user_id)

    with :ok <- PasswordHash.verify(current_password, user.hashed_password),
         :ok <- validate_password_strength(new_password),
         {:ok, hashed} <- PasswordHash.hash(new_password) do
      user
      |> User.changeset(%{hashed_password: hashed, password_changed_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  def deactivate(user_id, reason) do
    user = Repo.get!(User, user_id)

    user
    |> User.changeset(%{
      status:          :deactivated,
      deactivated_at:  DateTime.utc_now(),
      deactivation_reason: reason
    })
    |> Repo.update()
  end

  def list_active_users do
    User
    |> Repo.all()
    |> Enum.filter(&(&1.status == :active))
  end

  def find_by_email(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil  -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  # --- Private ---

  defp validate_email_format(email) do
    if String.contains?(email, "@") and String.contains?(email, ".") do
      :ok
    else
      {:error, :invalid_email_format}
    end
  end

  defp validate_password_strength(password) do
    cond do
      String.length(password) < @min_password_length ->
        {:error, :password_too_short}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, :password_needs_digit}

      true ->
        :ok
    end
  end
end

# VALIDATION: SMELL START - Speculative Generality
# VALIDATION: This is a smell because `UserManagement.ConsentTracker` is a fully
# implemented module that was created speculatively to handle granular GDPR consent
# tracking. The main module `UserManagement.AccountService` never calls any
# function from this module—consent is stored only as a boolean field on the user
# record. The module is dead code that provides no value and must be unnecessarily
# maintained.
defmodule UserManagement.ConsentTracker do
  @moduledoc """
  Tracks GDPR and marketing consent records per user.
  Maintains a full audit trail of consent grants and withdrawals,
  supporting data subject access requests and right-to-erasure workflows.
  """

  alias UserManagement.{ConsentRecord, Repo}

  @consent_types [:gdpr_processing, :marketing_email, :analytics, :third_party_sharing]

  def record_consent(user_id, consent_type, granted, ip_address) when consent_type in @consent_types do
    attrs = %{
      user_id:      user_id,
      consent_type: consent_type,
      granted:      granted,
      ip_address:   ip_address,
      recorded_at:  DateTime.utc_now()
    }

    ConsentRecord.changeset(%ConsentRecord{}, attrs) |> Repo.insert()
  end

  def current_consent(user_id, consent_type) do
    ConsentRecord
    |> Repo.all()
    |> Enum.filter(&(&1.user_id == user_id and &1.consent_type == consent_type))
    |> Enum.max_by(& &1.recorded_at, DateTime, fn -> nil end)
    |> case do
      nil    -> {:ok, :unknown}
      record -> {:ok, if(record.granted, do: :granted, else: :withdrawn)}
    end
  end

  def withdraw_all(user_id) do
    Enum.each(@consent_types, fn type ->
      record_consent(user_id, type, false, "system")
    end)
  end

  def audit_trail(user_id) do
    ConsentRecord
    |> Repo.all()
    |> Enum.filter(&(&1.user_id == user_id))
    |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})
  end
end
# VALIDATION: SMELL END
```
