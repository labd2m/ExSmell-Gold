```elixir
defmodule Crm.Contacts.ContactContext do
  @moduledoc """
  Public context for managing CRM contacts.
  Provides create, update, search, and archival operations
  with explicit result tuples at every boundary.
  """

  alias Crm.Contacts.{Contact, ContactQuery}
  alias Crm.Repo

  @doc """
  Creates a new contact from the given attributes.
  """
  @spec create(map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing contact.
  """
  @spec update(Contact.t(), map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Contact{} = contact, attrs) when is_map(attrs) do
    contact
    |> Contact.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Fetches a contact by ID. Returns `{:error, :not_found}` when absent.
  """
  @spec fetch(String.t()) :: {:ok, Contact.t()} | {:error, :not_found}
  def fetch(id) when is_binary(id) do
    case Repo.get(Contact, id) do
      nil -> {:error, :not_found}
      contact -> {:ok, contact}
    end
  end

  @doc """
  Returns a paginated list of contacts matching `filters`.

  ## Options
    - `:page` - 1-based page index (default: 1)
    - `:per_page` - results per page, max 50 (default: 25)
    - `:query` - optional full-name search string
  """
  @spec list(keyword()) :: {:ok, [Contact.t()], map()} | {:error, String.t()}
  def list(opts \\ []) do
    with {:ok, page} <- validate_page(opts),
         {:ok, per_page} <- validate_per_page(opts) do
      contacts =
        ContactQuery.base()
        |> ContactQuery.search(Keyword.get(opts, :query))
        |> ContactQuery.active_only()
        |> ContactQuery.paginate(page, per_page)
        |> Repo.all()

      {:ok, contacts, %{page: page, per_page: per_page}}
    end
  end

  @doc """
  Archives a contact, preventing it from appearing in active listings.
  """
  @spec archive(Contact.t()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Contact{} = contact) do
    contact
    |> Contact.archive_changeset()
    |> Repo.update()
  end

  @doc """
  Permanently deletes a contact record.
  """
  @spec delete(Contact.t()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Contact{} = contact) do
    Repo.delete(contact)
  end

  defp validate_page(opts) do
    val = Keyword.get(opts, :page, 1)

    if is_integer(val) and val >= 1 do
      {:ok, val}
    else
      {:error, "page must be a positive integer"}
    end
  end

  defp validate_per_page(opts) do
    val = Keyword.get(opts, :per_page, 25)

    cond do
      not is_integer(val) -> {:error, "per_page must be an integer"}
      val < 1 -> {:error, "per_page must be at least 1"}
      val > 50 -> {:error, "per_page cannot exceed 50"}
      true -> {:ok, val}
    end
  end
end
```
