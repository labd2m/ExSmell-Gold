```elixir
defmodule Accounts.Profiles do
  @moduledoc """
  Context for managing user profile data, including structured addresses and preferences.

  Address handling is encapsulated in a dedicated struct to avoid raw map fragility.
  """

  import Ecto.Query

  alias Accounts.Repo
  alias Accounts.Profiles.{Profile, Address, Preference}

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Creates a profile for a user, optionally including a primary address.
  """
  @spec create(String.t(), map()) :: result(Profile.t())
  def create(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    %Profile{}
    |> Profile.create_changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Returns a profile by user ID, preloading addresses and preferences.
  """
  @spec get_by_user(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_by_user(user_id) when is_binary(user_id) do
    Profile
    |> where([p], p.user_id == ^user_id)
    |> preload([:addresses, :preferences])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Updates profile fields for a user.
  """
  @spec update(Profile.t(), map()) :: result(Profile.t())
  def update(%Profile{} = profile, attrs) when is_map(attrs) do
    profile
    |> Profile.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Adds an address to a profile, optionally marking it as primary.
  """
  @spec add_address(Profile.t(), Address.attrs()) :: result(Address.t())
  def add_address(%Profile{id: profile_id}, address_attrs) when is_map(address_attrs) do
    Repo.transaction(fn ->
      make_primary = Map.get(address_attrs, :primary, false)

      if make_primary do
        Profile
        |> join(:inner, [p], a in assoc(p, :addresses))
        |> where([_, a], a.profile_id == ^profile_id)
        |> Repo.update_all(set: [primary: false])
      end

      %Address{}
      |> Address.changeset(Map.put(address_attrs, :profile_id, profile_id))
      |> Repo.insert()
      |> case do
        {:ok, addr} -> addr
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Removes an address from a profile by address ID.
  """
  @spec remove_address(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_address(profile_id, address_id)
      when is_binary(profile_id) and is_binary(address_id) do
    deleted =
      Address
      |> where([a], a.id == ^address_id and a.profile_id == ^profile_id)
      |> Repo.delete_all()

    case deleted do
      {0, _} -> {:error, "address not found"}
      {_, _} -> :ok
    end
  end

  @doc """
  Upserts a named preference for a profile.
  """
  @spec set_preference(String.t(), String.t(), String.t()) :: result(Preference.t())
  def set_preference(profile_id, key, value)
      when is_binary(profile_id) and is_binary(key) and is_binary(value) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert(
      %Preference{profile_id: profile_id, key: key, value: value,
                  inserted_at: now, updated_at: now},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:profile_id, :key]
    )
  end

  @doc """
  Returns all preferences for a profile as a flat keyword map.
  """
  @spec get_preferences(String.t()) :: %{String.t() => String.t()}
  def get_preferences(profile_id) when is_binary(profile_id) do
    Preference
    |> where([pref], pref.profile_id == ^profile_id)
    |> Repo.all()
    |> Map.new(fn %Preference{key: k, value: v} -> {k, v} end)
  end
end

defmodule Accounts.Profiles.Address do
  @moduledoc "Embedded address struct used in user profiles."

  use Ecto.Schema
  import Ecto.Changeset

  @type attrs :: %{
          optional(:line1) => String.t(),
          optional(:city) => String.t(),
          optional(:country_code) => String.t(),
          optional(:primary) => boolean()
        }

  schema "profile_addresses" do
    field :profile_id, :string
    field :line1, :string
    field :line2, :string
    field :city, :string
    field :state, :string
    field :postal_code, :string
    field :country_code, :string
    field :primary, :boolean, default: false
    timestamps()
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [:profile_id, :line1, :line2, :city, :state, :postal_code, :country_code, :primary])
    |> validate_required([:profile_id, :line1, :city, :country_code])
    |> validate_length(:country_code, is: 2)
  end
end
```
