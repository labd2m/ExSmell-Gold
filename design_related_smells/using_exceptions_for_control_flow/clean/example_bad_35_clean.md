```elixir
defmodule ProfileStore do
  @moduledoc """
  Manages user profile data updates with field-level validation
  and uniqueness enforcement across the platform.
  """

  defmodule UsernameChangeProhibitedError do
    defexception [:message, :user_id, :last_changed_at, :next_allowed_at]
  end

  defmodule DuplicateDisplayNameError do
    defexception [:message, :display_name]
  end

  defmodule InvalidFieldError do
    defexception [:message, :field, :value]
  end

  defmodule UnknownUserError do
    defexception [:message, :user_id]
  end

  @username_change_cooldown_days 30
  @display_name_regex ~r/^[a-zA-Z0-9 _\-\.]{2,50}$/
  @bio_max_length 500

  @users %{
    "usr-001" => %{
      id: "usr-001",
      display_name: "Alice Wonder",
      bio: "Software engineer",
      username_last_changed: ~U[2025-08-01 00:00:00Z]
    },
    "usr-002" => %{
      id: "usr-002",
      display_name: "Bob Builder",
      bio: nil,
      username_last_changed: nil
    }
  }

  @taken_display_names MapSet.new(["Admin", "Support", "System", "Alice Wonder"])

  def update(user_id, changes) do
    user = Map.get(@users, user_id)

    if is_nil(user) do
      raise UnknownUserError,
        message: "No user found with ID '#{user_id}'",
        user_id: user_id
    end

    if Map.has_key?(changes, :username) and not is_nil(user.username_last_changed) do
      days_since = DateTime.diff(DateTime.utc_now(), user.username_last_changed, :second) |> div(86_400)

      if days_since < @username_change_cooldown_days do
        next_allowed = DateTime.add(user.username_last_changed, @username_change_cooldown_days * 86_400, :second)

        raise UsernameChangeProhibitedError,
          message:
            "Username can only be changed every #{@username_change_cooldown_days} days. " <>
              "Next allowed: #{next_allowed}",
          user_id: user_id,
          last_changed_at: user.username_last_changed,
          next_allowed_at: next_allowed
      end
    end

    if Map.has_key?(changes, :display_name) do
      name = changes.display_name

      unless Regex.match?(@display_name_regex, name) do
        raise InvalidFieldError,
          message: "Display name '#{name}' contains invalid characters or is outside 2–50 characters",
          field: :display_name,
          value: name
      end

      if MapSet.member?(@taken_display_names, name) and name != user.display_name do
        raise DuplicateDisplayNameError,
          message: "Display name '#{name}' is already in use",
          display_name: name
      end
    end

    if Map.has_key?(changes, :bio) and is_binary(changes.bio) do
      if String.length(changes.bio) > @bio_max_length do
        raise InvalidFieldError,
          message: "Bio exceeds the maximum length of #{@bio_max_length} characters",
          field: :bio,
          value: changes.bio
      end
    end

    updated_user = Map.merge(user, changes)
    Map.put(updated_user, :updated_at, DateTime.utc_now())
  end
end

defmodule AccountSettings do
  @moduledoc """
  Processes profile update requests submitted from the account settings page.
  """

  require Logger

  def apply_changes(user_id, raw_changes) do
    changes = Enum.reduce(raw_changes, %{}, fn {k, v}, acc ->
      Map.put(acc, String.to_existing_atom(k), v)
    end)

    Logger.info("Applying profile changes for user #{user_id}: #{Map.keys(changes) |> inspect()}")

    # violations are everyday validation outcomes on a profile-settings page.
    # The client is forced to catch exceptions for these cases because
    # ProfileStore.update/2 provides no tuple-based result option.
    try do
      updated = ProfileStore.update(user_id, changes)
      Logger.info("Profile updated for user #{user_id}")
      {:ok, updated}
    rescue
      e in ProfileStore.UsernameChangeProhibitedError ->
        Logger.info("Username change denied for #{e.user_id}; next allowed #{e.next_allowed_at}")
        {:error, :username_cooldown, e.next_allowed_at}

      e in ProfileStore.DuplicateDisplayNameError ->
        Logger.debug("Display name '#{e.display_name}' already taken")
        {:error, :display_name_taken, e.display_name}

      e in ProfileStore.InvalidFieldError ->
        Logger.debug("Invalid value for field #{e.field}: #{inspect(e.value)}")
        {:error, {:invalid_field, e.field}, e.message}

      e in ProfileStore.UnknownUserError ->
        Logger.error("Profile update for unknown user #{e.user_id}")
        {:error, :user_not_found}
    end
  end
end
```
