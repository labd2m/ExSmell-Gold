```elixir
defmodule Accounts.ProfileService do
  @moduledoc """
  Manages user profile creation, name updates, display name generation,
  and name-based search for the customer accounts platform.
  """

  require Logger

  alias Accounts.Repo
  alias Accounts.Schema.{UserProfile, User}

  @max_name_length 50
  @min_name_length 1


  @spec create_profile(User.t(), {String.t(), String.t()}) ::
          {:ok, UserProfile.t()} | {:error, term()}
  def create_profile(%User{} = user, {first_name, last_name})
      when is_binary(first_name) and is_binary(last_name) do
    with :ok <- validate_name_part(first_name, :first),
         :ok <- validate_name_part(last_name, :last) do
      display_name = generate_display_name({first_name, last_name})
      initials = build_initials(first_name, last_name)
      sort_key = String.downcase("#{last_name}, #{first_name}")

      attrs = %{
        user_id: user.id,
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        display_name: display_name,
        initials: initials,
        sort_key: sort_key,
        created_at: DateTime.utc_now()
      }

      case %UserProfile{} |> UserProfile.changeset(attrs) |> Repo.insert() do
        {:ok, profile} ->
          Logger.info("Profile created: user=#{user.id} display=#{display_name}")
          {:ok, profile}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  @spec update_name(UserProfile.t(), {String.t(), String.t()}) ::
          {:ok, UserProfile.t()} | {:error, term()}
  def update_name(%UserProfile{} = profile, {new_first, new_last})
      when is_binary(new_first) and is_binary(new_last) do
    with :ok <- validate_name_part(new_first, :first),
         :ok <- validate_name_part(new_last, :last) do
      new_display = generate_display_name({new_first, new_last})
      new_initials = build_initials(new_first, new_last)
      new_sort_key = String.downcase("#{new_last}, #{new_first}")

      profile
      |> UserProfile.changeset(%{
        first_name: String.trim(new_first),
        last_name: String.trim(new_last),
        display_name: new_display,
        initials: new_initials,
        sort_key: new_sort_key,
        updated_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end

  @spec generate_display_name({String.t(), String.t()}) :: String.t()
  def generate_display_name({first_name, last_name})
      when is_binary(first_name) and is_binary(last_name) do
    first = first_name |> String.trim() |> capitalize_name()
    last = last_name |> String.trim() |> capitalize_name()
    "#{first} #{last}"
  end

  @spec search_by_name(String.t(), String.t()) :: list(UserProfile.t())
  def search_by_name(first_fragment, last_fragment)
      when is_binary(first_fragment) and is_binary(last_fragment) do
    first_pattern = "%#{String.downcase(first_fragment)}%"
    last_pattern = "%#{String.downcase(last_fragment)}%"

    Repo.all(
      from p in UserProfile,
        where:
          like(fragment("lower(?)", p.first_name), ^first_pattern) and
            like(fragment("lower(?)", p.last_name), ^last_pattern),
        order_by: [asc: p.sort_key],
        limit: 50
    )
  end

  @spec format_formal(String.t(), String.t()) :: String.t()
  def format_formal(first_name, last_name)
      when is_binary(first_name) and is_binary(last_name) do
    last = last_name |> String.trim() |> capitalize_name()
    first_initial = first_name |> String.trim() |> String.at(0) |> String.upcase()
    "#{last}, #{first_initial}."
  end


  ## Private helpers

  defp validate_name_part(name, field) when is_binary(name) do
    cond do
      String.length(String.trim(name)) < @min_name_length ->
        {:error, {:name_too_short, field}}

      String.length(name) > @max_name_length ->
        {:error, {:name_too_long, field}}

      not Regex.match?(~r/^[\p{L}\s'\-\.]+$/u, String.trim(name)) ->
        {:error, {:invalid_name_characters, field}}

      true ->
        :ok
    end
  end

  defp build_initials(first_name, last_name) do
    f = first_name |> String.trim() |> String.at(0) |> String.upcase()
    l = last_name |> String.trim() |> String.at(0) |> String.upcase()
    "#{f}#{l}"
  end

  defp capitalize_name(name) do
    name
    |> String.split(~r/[\s\-]/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
```