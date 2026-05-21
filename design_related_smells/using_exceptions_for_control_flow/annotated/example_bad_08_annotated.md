# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Accounts.ProfileValidator.validate_and_apply/2`
- **Affected function(s):** `Accounts.ProfileValidator.validate_and_apply/2` (library side); `Accounts.ProfileUpdateHandler.handle/2` (client side)
- **Explanation:** `validate_and_apply/2` raises `RuntimeError` for predictable validation failures: blank display name, invalid email format, and username already taken. Profile update failures are not exceptional — they are expected user input errors. Callers must use `try/rescue` to distinguish a validation error from a successful update, making this the only available control-flow mechanism.

```elixir
defmodule Accounts.User do
  @moduledoc "Core user struct with profile fields."

  @enforce_keys [:id, :email, :username, :display_name, :status]
  defstruct [:id, :email, :username, :display_name, :bio, :avatar_url, :status, :updated_at]
end

defmodule Accounts.UserStore do
  @moduledoc "Simple in-memory user persistence stub."

  alias Accounts.User

  @users %{
    "u_001" => %User{
      id: "u_001",
      email: "alice@example.com",
      username: "alice",
      display_name: "Alice Wonderland",
      status: :active
    },
    "u_002" => %User{
      id: "u_002",
      email: "bob@example.com",
      username: "bob",
      display_name: "Bob Builder",
      status: :active
    }
  }

  def find(id), do: Map.fetch(@users, id)

  def username_taken?(username), do: Enum.any?(@users, fn {_, u} -> u.username == username end)

  def email_taken?(email), do: Enum.any?(@users, fn {_, u} -> u.email == email end)

  def update(%User{} = user), do: {:ok, %{user | updated_at: DateTime.utc_now()}}
end

defmodule Accounts.ProfileValidator do
  @moduledoc """
  Validates profile update parameters and applies them to an existing user record.
  Used by the web and API layers during profile edit flows.
  """

  alias Accounts.{User, UserStore}
  require Logger

  @max_bio_length 500
  @username_regex ~r/^[a-z0-9_]{3,30}$/

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `validate_and_apply/2` raises RuntimeError
  # VALIDATION: for ordinary, expected validation failures: blank display name,
  # VALIDATION: invalid email, username format error, username/email already taken.
  # VALIDATION: These are standard form-validation outcomes, not system exceptions.
  # VALIDATION: Callers are unable to inspect a structured error reason without
  # VALIDATION: catching the RuntimeError, making try/rescue unavoidable.
  def validate_and_apply(%User{} = user, params) when is_map(params) do
    display_name = Map.get(params, :display_name, user.display_name)

    if is_nil(display_name) or String.trim(display_name) == "" do
      raise RuntimeError, message: "Display name cannot be blank"
    end

    new_email = Map.get(params, :email, user.email)

    unless String.match?(new_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      raise RuntimeError, message: "Email '#{new_email}' is not a valid address"
    end

    if new_email != user.email and UserStore.email_taken?(new_email) do
      raise RuntimeError, message: "Email '#{new_email}' is already in use by another account"
    end

    new_username = Map.get(params, :username, user.username)

    unless String.match?(new_username, @username_regex) do
      raise RuntimeError,
        message:
          "Username '#{new_username}' is invalid. Must be 3-30 characters, " <>
            "lowercase letters, digits, or underscores only."
    end

    if new_username != user.username and UserStore.username_taken?(new_username) do
      raise RuntimeError, message: "Username '#{new_username}' is already taken"
    end

    bio = Map.get(params, :bio, user.bio)

    if is_binary(bio) and String.length(bio) > @max_bio_length do
      raise RuntimeError,
        message: "Bio exceeds the maximum length of #{@max_bio_length} characters"
    end

    updated_user = %User{
      user
      | display_name: display_name,
        email: new_email,
        username: new_username,
        bio: bio,
        avatar_url: Map.get(params, :avatar_url, user.avatar_url)
    }

    {:ok, persisted} = UserStore.update(updated_user)
    Logger.info("Profile updated for user=#{user.id}")
    persisted
  end
  # VALIDATION: SMELL END
end

defmodule Accounts.ProfileUpdateHandler do
  @moduledoc """
  Orchestrates profile update requests coming from the web controller.
  Resolves the user, delegates validation, and returns a structured response.
  """

  alias Accounts.{ProfileValidator, UserStore}
  require Logger

  def handle(user_id, params) do
    case UserStore.find(user_id) do
      :error ->
        {:error, :not_found}

      {:ok, user} ->
        # Client forced to use try/rescue because ProfileValidator.validate_and_apply/2
        # raises on validation failures instead of returning {:error, reason}.
        try do
          updated_user = ProfileValidator.validate_and_apply(user, params)
          {:ok, updated_user}
        rescue
          e in RuntimeError ->
            Logger.warning("Profile update failed for user=#{user_id}: #{e.message}")
            {:error, e.message}
        end
    end
  end

  def handle_bulk(updates) when is_list(updates) do
    Enum.map(updates, fn %{user_id: uid, params: p} ->
      %{user_id: uid, result: handle(uid, p)}
    end)
  end
end
```
