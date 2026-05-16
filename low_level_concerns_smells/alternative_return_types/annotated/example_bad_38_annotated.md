# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Accounts.UserProfile.get/2`, around the `opts[:fields]` and `opts[:as]` checks
- **Affected function(s):** `get/2`
- **Short explanation:** The function returns a full `%User{}` struct, a `Keyword.t()` list, or a plain `map` with only selected keys depending on the `:as` and `:fields` options, creating an unstable public contract.

---

```elixir
defmodule Accounts.UserProfile do
  @moduledoc """
  Read-only projection layer for user account data.
  Provides flexible retrieval for different consumers (API, background jobs, UI).
  """

  alias Accounts.Repo
  alias Accounts.Schema.User

  @public_fields [:id, :email, :display_name, :avatar_url, :timezone, :locale]

  @doc """
  Retrieves a user's profile by user ID.

  ## Options

    * `:fields` — List of field atoms to include. Defaults to all public fields.
      Only used when `:as` is `:map` or `:keyword`.
    * `:as` — Controls the return shape:
      - `:struct` (default) — Returns `%User{}`.
      - `:map` — Returns `%{field => value}` for selected fields.
      - `:keyword` — Returns a `Keyword.t()` list.

  ## Examples

      iex> get(1)
      %User{id: 1, email: "bob@example.com", ...}

      iex> get(1, as: :map, fields: [:email, :display_name])
      %{email: "bob@example.com", display_name: "Bob"}

      iex> get(1, as: :keyword, fields: [:email, :timezone])
      [email: "bob@example.com", timezone: "America/New_York"]

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because depending on the :as option the caller
  # VALIDATION: receives a %User{} struct, a plain Map, or a Keyword list.
  # VALIDATION: All three are structurally different; downstream code that
  # VALIDATION: calls `get/2` must always carry knowledge of which :as value
  # VALIDATION: was used in order to safely access the returned data.
  def get(user_id, opts \\ []) when is_list(opts) do
    user = Repo.get!(User, user_id)
    fields = Keyword.get(opts, :fields, @public_fields)

    case Keyword.get(opts, :as, :struct) do
      :map ->
        Map.take(user, fields)

      :keyword ->
        user
        |> Map.take(fields)
        |> Enum.into([])

      _ ->
        user
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the public display name for a user, falling back to email prefix.
  """
  def display_name(user_id) do
    user = Repo.get!(User, user_id)
    user.display_name || String.split(user.email, "@") |> hd()
  end

  @doc """
  Updates mutable profile fields for a user.

  Only allows changes to non-sensitive fields.
  """
  def update(user_id, attrs) do
    allowed_attrs = Map.take(attrs, [:display_name, :avatar_url, :timezone, :locale])

    user_id
    |> Repo.get!(User)
    |> User.profile_changeset(allowed_attrs)
    |> Repo.update()
  end

  @doc """
  Returns a list of recently active users (active within the last N days).
  """
  def recently_active(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    User
    |> Repo.all_by_query(fn q ->
      import Ecto.Query
      where(q, [u], u.last_active_at >= ^cutoff and u.active == true)
    end)
    |> Enum.sort_by(& &1.last_active_at, {:desc, DateTime})
  end

  @doc """
  Marks a user as having been active right now.
  """
  def touch_activity(user_id) do
    user = Repo.get!(User, user_id)

    user
    |> User.activity_changeset(%{last_active_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  @doc """
  Checks whether a user has completed their profile setup.
  """
  def profile_complete?(%User{display_name: nil}), do: false
  def profile_complete?(%User{avatar_url: nil}), do: false
  def profile_complete?(%User{timezone: nil}), do: false
  def profile_complete?(%User{}), do: true
end
```
