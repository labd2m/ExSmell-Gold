```elixir
defmodule Tenancy.AccountContext do
  @moduledoc """
  Manages multi-tenant account lifecycle: creation, suspension, and
  data retrieval. Every query is scoped to the calling tenant's ID so
  cross-tenant data leakage is impossible at the context boundary.
  Structural changes and domain invariants are encoded in named changesets
  rather than scattered across controller or background-job layers.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Tenancy.{Account, Member, Invitation}

  @type tenant_id :: Ecto.UUID.t()
  @type account_id :: Ecto.UUID.t()
  @type create_params :: %{name: String.t(), owner_id: String.t(), plan_id: String.t()}

  @doc """
  Creates a new account and inserts the owner as its first member inside
  a single database transaction.
  """
  @spec create_account(create_params()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(%{name: _, owner_id: owner_id, plan_id: _} = params) do
    Repo.transaction(fn ->
      with {:ok, account} <- insert_account(params),
           {:ok, _member} <- insert_owner_member(account.id, owner_id) do
        account
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Fetches an account by ID, returning `{:error, :not_found}` when absent
  or when the account does not belong to `tenant_id`.
  """
  @spec fetch_account(tenant_id(), account_id()) ::
          {:ok, Account.t()} | {:error, :not_found}
  def fetch_account(tenant_id, account_id)
      when is_binary(tenant_id) and is_binary(account_id) do
    query =
      from a in Account,
        where: a.id == ^account_id and a.tenant_id == ^tenant_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  @doc "Lists all active accounts belonging to `tenant_id`."
  @spec list_accounts(tenant_id()) :: [Account.t()]
  def list_accounts(tenant_id) when is_binary(tenant_id) do
    Account
    |> where([a], a.tenant_id == ^tenant_id and a.status == "active")
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
  end

  @doc "Suspends an account, preventing further access for its members."
  @spec suspend(Account.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :already_suspended | Ecto.Changeset.t()}
  def suspend(%Account{status: "suspended"}, _reason), do: {:error, :already_suspended}

  def suspend(%Account{} = account, reason) when is_binary(reason) do
    account
    |> Account.suspension_changeset(%{status: "suspended", suspension_reason: reason})
    |> Repo.update()
  end

  @doc "Returns the number of members in the given account."
  @spec member_count(account_id()) :: non_neg_integer()
  def member_count(account_id) when is_binary(account_id) do
    Member
    |> where([m], m.account_id == ^account_id)
    |> select([m], count(m.id))
    |> Repo.one()
  end

  @doc "Returns all pending invitations for the given account."
  @spec pending_invitations(account_id()) :: [Invitation.t()]
  def pending_invitations(account_id) when is_binary(account_id) do
    Invitation
    |> where([i], i.account_id == ^account_id and i.status == "pending")
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
  end

  defp insert_account(params) do
    %Account{} |> Account.creation_changeset(params) |> Repo.insert()
  end

  defp insert_owner_member(account_id, owner_id) do
    attrs = %{account_id: account_id, user_id: owner_id, role: "owner"}
    %Member{} |> Member.changeset(attrs) |> Repo.insert()
  end
end
```
