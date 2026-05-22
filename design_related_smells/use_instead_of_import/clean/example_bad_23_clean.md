```elixir
defmodule Accounts.SanitizeHelpers do
  @moduledoc """
  Stateless string sanitisation, normalisation, and validation helpers
  for user-profile fields.
  """

  def sanitize_text(nil),  do: ""
  def sanitize_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/[<>]/, "")
  end

  def normalize_username(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-]/, "")
    |> String.trim("_")
    |> String.trim("-")
  end

  def valid_email?(email) when is_binary(email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end

  def valid_username?(username) when is_binary(username) do
    Regex.match?(~r/^[a-z0-9_\-]{3,32}$/, username)
  end

  def valid_url?(nil), do: true
  def valid_url?(url) when is_binary(url) do
    Regex.match?(~r|^https?://[^\s]+$|, url)
  end

  def truncate_bio(bio, max) when is_binary(bio) and is_integer(max) do
    if String.length(bio) > max do
      String.slice(bio, 0, max)
    else
      bio
    end
  end

  defmacro __using__(_opts) do
    quote do
      import Accounts.SanitizeHelpers
      alias Accounts.AvatarStore

      @max_bio_length      500
      @max_username_length  32
    end
  end
end

defmodule Accounts.AvatarStore do
  @moduledoc "Manages user avatar uploads and URL resolution (stub)."

  def upload(user_id, image_data) do
    key = "avatars/#{user_id}/#{System.system_time(:millisecond)}.jpg"
    IO.puts("[AvatarStore] Uploading avatar for #{user_id} → #{key}")
    {:ok, %{key: key, url: "https://cdn.example.com/#{key}"}}
  end

  def delete(user_id) do
    IO.puts("[AvatarStore] Deleting avatar for #{user_id}")
    :ok
  end

  def url_for(user_id) do
    "https://cdn.example.com/avatars/#{user_id}/latest.jpg"
  end
end

defmodule Accounts.ProfileUpdater do
  use Accounts.SanitizeHelpers

  @moduledoc """
  Applies validated, sanitised updates to user profiles and coordinates
  avatar management with the CDN-backed storage service.
  """

  def update(user, params) do
    with {:ok, clean_params} <- validate_fields(params) do
      updated_user = apply_changes(user, clean_params)
      {:ok, updated_user}
    end
  end

  def validate_fields(params) do
    errors =
      []
      |> maybe_error(:email,    params[:email],    &(not valid_email?(&1)),    "Invalid email format")
      |> maybe_error(:username, params[:username], &(not valid_username?(normalize_username(&1))), "Invalid username")
      |> maybe_error(:website,  params[:website],  &(not valid_url?(&1)),      "Invalid URL")

    if errors == [] do
      {:ok, params}
    else
      {:error, errors}
    end
  end

  def apply_changes(user, params) do
    user
    |> maybe_put(:email,    params[:email] && sanitize_text(params[:email]))
    |> maybe_put(:username, params[:username] && normalize_username(params[:username]))
    |> maybe_put(:bio,      params[:bio] && params[:bio] |> sanitize_text() |> truncate_bio(@max_bio_length))
    |> maybe_put(:website,  params[:website] && sanitize_text(params[:website]))
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  def update_avatar(user, image_data) do
    case AvatarStore.upload(user.id, image_data) do
      {:ok, %{url: url}} ->
        {:ok, Map.put(user, :avatar_url, url)}
      {:error, _} = err ->
        err
    end
  end

  def remove_avatar(user) do
    AvatarStore.delete(user.id)
    {:ok, Map.put(user, :avatar_url, nil)}
  end

  def render_public(user) do
    %{
      id:         user.id,
      username:   user.username,
      bio:        user[:bio],
      website:    user[:website],
      avatar_url: AvatarStore.url_for(user.id)
    }
  end

  defp maybe_put(map, _key, nil),   do: map
  defp maybe_put(map, key, value),  do: Map.put(map, key, value)

  defp maybe_error(errors, _field, nil, _pred, _msg), do: errors
  defp maybe_error(errors, field, value, pred, msg) do
    if pred.(value), do: [{field, msg} | errors], else: errors
  end
end
```
