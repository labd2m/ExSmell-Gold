# Annotated Example 09 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Accounts.User`
- **Affected functions:** `Accounts.User.register/1` (file one) and `Accounts.User.update_profile/2` (file two)
- **Explanation:** `Accounts.User` is declared in `lib/accounts/user.ex` and also in `lib/accounts/user_profile.ex`. The BEAM allows only one module per name in its module table. Whichever file is compiled second silently overwrites the first, making half of the user management API permanently unavailable.

---

```elixir
# ── file: lib/accounts/user.ex ────────────────────────────────────────────────

defmodule Accounts.User do
  @moduledoc """
  Core user entity. Handles registration, password management, and
  account-level operations such as verification and suspension.
  """

  alias Accounts.{PasswordHasher, EmailVerifier, Repo, AuditLog}

  @min_password_length 12
  @max_login_attempts 5

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          password_hash: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          roles: [String.t()],
          email_verified: boolean(),
          active: boolean(),
          failed_login_attempts: non_neg_integer(),
          locked_until: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :email,
    :password_hash,
    :first_name,
    :last_name,
    :locked_until,
    :created_at,
    :updated_at,
    roles: ["user"],
    email_verified: false,
    active: true,
    failed_login_attempts: 0
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Accounts.User` is defined once more in
  # `lib/accounts/user_profile.ex`. BEAM resolves module names as atoms; the
  # second-compiled file wins. `register/1` and `authenticate/2` will vanish
  # from memory if the profile file is compiled after this one.

  @spec register(map()) :: {:ok, t()} | {:error, map()}
  def register(attrs) do
    with {:ok, email} <- validate_email(attrs[:email]),
         {:ok, password} <- validate_password(attrs[:password]),
         :ok <- check_email_unique(email) do
      hash = PasswordHasher.hash(password)
      now = DateTime.utc_now()

      user = %__MODULE__{
        id: generate_id(),
        email: String.downcase(email),
        password_hash: hash,
        first_name: attrs[:first_name],
        last_name: attrs[:last_name],
        created_at: now,
        updated_at: now
      }

      Repo.insert(:users, user)
      EmailVerifier.send_verification(user)
      AuditLog.write(:user_registered, %{user_id: user.id})

      {:ok, user}
    end
  end

  # VALIDATION: SMELL END

  @spec authenticate(String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def authenticate(email, password) do
    case Repo.get_by(:users, email: String.downcase(email)) do
      nil ->
        PasswordHasher.dummy_check()
        {:error, :invalid_credentials}

      %{active: false} ->
        {:error, :account_inactive}

      %{locked_until: locked_until} = user when not is_nil(locked_until) ->
        if DateTime.compare(locked_until, DateTime.utc_now()) == :gt do
          {:error, :account_locked}
        else
          check_password(user, password)
        end

      user ->
        check_password(user, password)
    end
  end

  defp check_password(%{password_hash: hash} = user, password) do
    if PasswordHasher.verify(password, hash) do
      Repo.update(:users, user.id, %{failed_login_attempts: 0, locked_until: nil})
      {:ok, user}
    else
      new_attempts = user.failed_login_attempts + 1

      if new_attempts >= @max_login_attempts do
        locked_until = DateTime.add(DateTime.utc_now(), 1800, :second)
        Repo.update(:users, user.id, %{failed_login_attempts: new_attempts, locked_until: locked_until})
      else
        Repo.update(:users, user.id, %{failed_login_attempts: new_attempts})
      end

      {:error, :invalid_credentials}
    end
  end

  defp validate_email(email) when is_binary(email) do
    if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/), do: {:ok, email}, else: {:error, %{email: "is invalid"}}
  end

  defp validate_password(pwd) when is_binary(pwd) and byte_size(pwd) >= @min_password_length, do: {:ok, pwd}
  defp validate_password(_), do: {:error, %{password: "is too short"}}

  defp check_email_unique(email) do
    case Repo.get_by(:users, email: email) do
      nil -> :ok
      _ -> {:error, %{email: "is already taken"}}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end


# ── file: lib/accounts/user_profile.ex ───────────────────────────────────────

defmodule Accounts.User do
  @moduledoc """
  Handles profile updates, preferences, and avatar management for users.
  Called by the profile settings controller and user-facing API.
  """

  alias Accounts.{Repo, AvatarStorage, AuditLog}

  @allowed_profile_fields [:first_name, :last_name, :bio, :timezone, :locale, :display_name]

  @spec update_profile(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def update_profile(user_id, attrs) do
    with {:ok, user} <- Repo.fetch(:users, user_id),
         {:ok, changes} <- validate_profile_changes(attrs) do
      updated = Repo.update(:users, user_id, changes)
      AuditLog.write(:profile_updated, %{user_id: user_id, changed_fields: Map.keys(changes)})
      {:ok, updated}
    end
  end

  @spec upload_avatar(String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_avatar(user_id, image_data, content_type) do
    with {:ok, _user} <- Repo.fetch(:users, user_id),
         {:ok, url} <- AvatarStorage.upload(user_id, image_data, content_type) do
      Repo.update(:users, user_id, %{avatar_url: url})
      {:ok, url}
    end
  end

  @spec update_preferences(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_preferences(user_id, prefs) do
    with {:ok, user} <- Repo.fetch(:users, user_id) do
      merged = Map.merge(Map.get(user, :preferences, %{}), prefs)
      updated = Repo.update(:users, user_id, %{preferences: merged})
      {:ok, updated}
    end
  end

  @spec deactivate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deactivate(user_id, reason) do
    with {:ok, _user} <- Repo.fetch(:users, user_id) do
      updated = Repo.update(:users, user_id, %{active: false, deactivated_at: DateTime.utc_now()})
      AuditLog.write(:user_deactivated, %{user_id: user_id, reason: reason})
      {:ok, updated}
    end
  end

  defp validate_profile_changes(attrs) do
    changes =
      attrs
      |> Map.take(@allowed_profile_fields)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(changes) == 0 do
      {:error, %{base: "no valid fields provided"}}
    else
      {:ok, changes}
    end
  end
end
```
