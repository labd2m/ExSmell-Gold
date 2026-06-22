```elixir
defmodule Accounts.Users do
  @moduledoc """
  Boundary context for user account lifecycle operations including
  registration, credential verification, profile management,
  and account deactivation.

  All database interactions are routed through `Accounts.Repo`. Callers
  should depend on this module's public API rather than querying user
  records directly.
  """

  import Ecto.Query, warn: false

  alias Accounts.Repo
  alias Accounts.Users.User

  @type registration_params :: %{
          required(:email) => String.t(),
          required(:password) => String.t(),
          optional(:display_name) => String.t()
        }

  @type profile_params :: %{
          optional(:display_name) => String.t(),
          optional(:timezone) => String.t()
        }

  @doc """
  Returns active users ordered by registration date, newest first.

  Accepts `:limit` and `:offset` keyword options for pagination.
  """
  @spec list_active(keyword()) :: [User.t()]
  def list_active(opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)

    User
    |> where([u], u.active == true)
    |> order_by([u], desc: u.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc "Fetches a single user by UUID. Returns `{:error, :not_found}` when absent."
  @spec get_by_id(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_by_id(id) when is_binary(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  @doc "Registers a new user and persists their hashed credential."
  @spec register(registration_params()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(params) do
    %User{}
    |> User.registration_changeset(params)
    |> Repo.insert()
  end

  @doc "Updates mutable profile fields for an existing user."
  @spec update_profile(User.t(), profile_params()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, params) do
    user
    |> User.profile_changeset(params)
    |> Repo.update()
  end

  @doc "Soft-deletes an account by marking it inactive."
  @spec deactivate(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def deactivate(%User{} = user) do
    user
    |> User.deactivation_changeset()
    |> Repo.update()
  end

  @doc """
  Verifies `email` and `password` against stored credentials.

  Returns the authenticated user on success. Returns `{:error, :invalid_credentials}`
  regardless of whether the email exists, to prevent user enumeration.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    email
    |> String.downcase()
    |> fetch_active_by_email()
    |> verify_password(password)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp fetch_active_by_email(email) do
    query = from(u in User, where: u.email == ^email and u.active == true)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp verify_password({:error, _}, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp verify_password({:ok, user}, password) do
    if Bcrypt.verify_pass(password, user.hashed_password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end
end
```
