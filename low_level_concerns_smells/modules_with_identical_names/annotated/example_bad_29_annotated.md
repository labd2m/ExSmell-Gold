# Annotated Example 29 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Accounts.UserProfile` declarations
- **Affected functions:** `Accounts.UserProfile.create/2`, `Accounts.UserProfile.update/2`, `Accounts.UserProfile.deactivate/1`, `Accounts.UserProfile.avatar_url/1`, `Accounts.UserProfile.display_name/1`
- **Short explanation:** Two separate source files both define `defmodule Accounts.UserProfile`. Because the BEAM can only hold one module definition per name, the second file's definition overwrites the first at load time, making every function exclusive to the first module permanently unreachable and breaking user profile operations throughout the application.

---

```elixir
# ── file: lib/accounts/user_profile.ex ──────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Accounts.UserProfile` is declared here
# and also in a second block below. BEAM will silently drop one definition,
# making user profile management functions permanently unavailable.

defmodule Accounts.UserProfile do
  @moduledoc """
  User profile entity and management operations for the accounts subsystem.
  Defined in `lib/accounts/user_profile.ex`.
  """

  alias Accounts.{ProfileStore, AvatarService, SlugGenerator}

  @max_bio_length 500
  @max_display_name_length 50
  @default_avatar "https://cdn.example.com/avatars/default.png"

  @type t :: %__MODULE__{
    id: String.t(),
    user_id: String.t(),
    display_name: String.t(),
    bio: String.t() | nil,
    avatar_key: String.t() | nil,
    slug: String.t(),
    website: String.t() | nil,
    location: String.t() | nil,
    is_public: boolean(),
    is_active: boolean(),
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  defstruct [
    :id,
    :user_id,
    :display_name,
    :bio,
    :avatar_key,
    :slug,
    :website,
    :location,
    is_public: true,
    is_active: true,
    created_at: nil,
    updated_at: nil
  ]

  @doc "Create a new profile for a user account."
  @spec create(String.t(), map()) :: {:ok, t()} | {:error, map()}
  def create(user_id, attrs) do
    with {:ok, validated} <- validate_attrs(attrs) do
      now = DateTime.utc_now()

      profile = %__MODULE__{
        id: generate_id(),
        user_id: user_id,
        display_name: validated.display_name,
        bio: Map.get(validated, :bio),
        slug: SlugGenerator.from_name(validated.display_name),
        website: Map.get(validated, :website),
        location: Map.get(validated, :location),
        is_public: Map.get(validated, :is_public, true),
        created_at: now,
        updated_at: now
      }

      ProfileStore.save(profile)
    end
  end

  @doc "Update mutable fields of an existing profile."
  @spec update(t(), map()) :: {:ok, t()} | {:error, map()}
  def update(%__MODULE__{} = profile, attrs) do
    with {:ok, validated} <- validate_attrs(attrs) do
      updated =
        profile
        |> Map.merge(Map.take(validated, [:display_name, :bio, :website, :location, :is_public]))
        |> Map.put(:updated_at, DateTime.utc_now())

      ProfileStore.save(updated)
    end
  end

  @doc "Soft-deactivate a profile without deleting it."
  @spec deactivate(t()) :: {:ok, t()} | {:error, String.t()}
  def deactivate(%__MODULE__{is_active: true} = profile) do
    updated = %{profile | is_active: false, updated_at: DateTime.utc_now()}
    ProfileStore.save(updated)
  end

  def deactivate(%__MODULE__{is_active: false}) do
    {:error, "Profile is already inactive"}
  end

  @doc "Return the fully qualified avatar URL for a profile."
  @spec avatar_url(t()) :: String.t()
  def avatar_url(%__MODULE__{avatar_key: nil}), do: @default_avatar

  def avatar_url(%__MODULE__{avatar_key: key}) do
    AvatarService.url(key)
  end

  @doc "Return the human-readable display name, falling back to the slug."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{display_name: name}) when is_binary(name) and name != "" do
    name
  end

  def display_name(%__MODULE__{slug: slug}), do: slug

  defp validate_attrs(attrs) do
    errors =
      []
      |> maybe_add_error(:display_name, attrs, fn v ->
        cond do
          not is_binary(v) -> "must be a string"
          String.length(v) > @max_display_name_length -> "too long (max #{@max_display_name_length})"
          true -> nil
        end
      end)
      |> maybe_add_error(:bio, attrs, fn v ->
        if is_binary(v) and String.length(v) > @max_bio_length,
          do: "too long (max #{@max_bio_length})",
          else: nil
      end)

    if errors == [], do: {:ok, attrs}, else: {:error, Map.new(errors)}
  end

  defp maybe_add_error(errors, field, attrs, validator) do
    case Map.get(attrs, field) do
      nil -> errors
      val -> if msg = validator.(val), do: [{field, msg} | errors], else: errors
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END

# ── file: lib/accounts/user_profile_search.ex  (full-text search added later;
#    developer accidentally gave it the same module name) ────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Accounts.UserProfile` overwrites the first
# in BEAM. Functions `create/2`, `update/2`, `deactivate/1`, `avatar_url/1`,
# and `display_name/1` become permanently unavailable after load.

defmodule Accounts.UserProfile do
  @moduledoc """
  Full-text search support for user profiles.
  Was intended to be `Accounts.UserProfile.Search` but was accidentally given
  the same module name as the core profile module.
  """

  alias Accounts.SearchIndex

  @search_fields [:display_name, :bio, :location, :slug]

  @doc "Index a profile for full-text search."
  @spec index(map()) :: :ok | {:error, String.t()}
  def index(%{id: id} = profile) do
    document =
      @search_fields
      |> Enum.map(fn field -> {field, Map.get(profile, field, "")} end)
      |> Map.new()

    SearchIndex.put("profiles", id, document)
  end

  @doc "Remove a profile from the search index."
  @spec deindex(String.t()) :: :ok | {:error, String.t()}
  def deindex(profile_id) do
    SearchIndex.delete("profiles", profile_id)
  end

  @doc "Search profiles by a free-text query, returning ranked results."
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    public_only = Keyword.get(opts, :public_only, true)

    filters = if public_only, do: %{is_public: true, is_active: true}, else: %{is_active: true}

    SearchIndex.query("profiles", query, filters: filters, limit: limit)
  end

  @doc "Re-index all active profiles (used for full re-build operations)."
  @spec reindex_all() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def reindex_all do
    profiles = Accounts.ProfileStore.all(is_active: true)

    results = Enum.map(profiles, fn p -> {p.id, index(p)} end)
    failed = for {id, {:error, _}} <- results, do: id

    if failed == [] do
      {:ok, length(profiles)}
    else
      {:error, "Failed to index #{length(failed)} profiles: #{Enum.join(failed, ", ")}"}
    end
  end
end

# VALIDATION: SMELL END
```
