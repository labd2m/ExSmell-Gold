```elixir
defmodule CRM.CustomerRepository do
  @moduledoc """
  Data access layer for customer records in the CRM domain.
  Provides flexible query, preloading, and projection options.
  """

  alias CRM.Repo
  alias CRM.Schema.{Customer, Contact}

  import Ecto.Query

  @doc """
  Finds customers matching the given filters.

  ## Options

    * `:name_like` — Substring match on the customer's company name.
    * `:tier` — Atom tier to filter by (`:free`, `:starter`, `:enterprise`).
    * `:account_manager_id` — Filter by assigned account manager.
    * `:ids_only` — When `true`, returns a list of integer customer IDs
      rather than full structs. Useful for bulk operations.
    * `:with_contacts` — When `true`, preloads the `:contacts` association
      on each returned `%Customer{}`. Cannot be combined with `:ids_only`.
    * `:limit` — Max number of results. Defaults to 50.

  ## Examples

      iex> find(tier: :enterprise)
      [%Customer{id: 1, ...}, %Customer{id: 2, ...}]

      iex> find(tier: :enterprise, ids_only: true)
      [1, 2, 17, 33]

      iex> find(tier: :starter, with_contacts: true)
      [%Customer{id: 5, contacts: [%Contact{...}], ...}, ...]

  """

  def find(filters \\ [], opts \\ []) when is_list(filters) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)

    base =
      Customer
      |> apply_filters(filters)
      |> order_by([c], asc: c.name)
      |> limit(^limit)

    cond do
      opts[:ids_only] == true ->
        base
        |> select([c], c.id)
        |> Repo.all()

      opts[:with_contacts] == true ->
        base
        |> Repo.all()
        |> Repo.preload(:contacts)

      true ->
        Repo.all(base)
    end
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:name_like, term}, q ->
        where(q, [c], ilike(c.name, ^"%#{term}%"))

      {:tier, tier}, q ->
        where(q, [c], c.tier == ^tier)

      {:account_manager_id, am_id}, q ->
        where(q, [c], c.account_manager_id == ^am_id)

      {:active, active}, q ->
        where(q, [c], c.active == ^active)

      _, q ->
        q
    end)
  end

  @doc """
  Inserts a new customer record.
  """
  def create(attrs) do
    %Customer{}
    |> Customer.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a customer record.
  """
  def update(%Customer{} = customer, attrs) do
    customer
    |> Customer.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns a single customer by ID or raises if not found.
  """
  def get!(customer_id), do: Repo.get!(Customer, customer_id)

  @doc """
  Archives a customer, preserving their data but hiding from active views.
  """
  def archive(%Customer{} = customer) do
    customer
    |> Customer.changeset(%{archived: true, archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Counts customers grouped by tier.
  """
  def counts_by_tier do
    Customer
    |> where([c], c.active == true)
    |> group_by([c], c.tier)
    |> select([c], {c.tier, count(c.id)})
    |> Repo.all()
    |> Map.new()
  end
end
```
