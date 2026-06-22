```elixir
defmodule MyApp.Seeds do
  @moduledoc """
  Deterministic database seed data for development and staging environments.
  Each seeder function is idempotent: records are looked up by a stable
  business key before insertion so running seeds multiple times does not
  duplicate data. All seeds are transactional so a partial failure leaves
  the database in a clean state.

  Seeds are intentionally realistic — they mirror production data shapes
  closely enough that UI development and manual testing feel authentic.
  """

  alias MyApp.{Accounts, Billing, Catalog, Repo}
  alias Ecto.Multi

  require Logger

  @doc """
  Runs all seed groups in dependency order. Safe to call repeatedly.
  Prints a summary of created vs existing records to stdout.
  """
  @spec run() :: :ok
  def run do
    Logger.info("Starting database seed run")

    {:ok, results} =
      Multi.new()
      |> Multi.run(:plans, fn _repo, _ -> seed_plans() end)
      |> Multi.run(:users, fn _repo, _ -> seed_users() end)
      |> Multi.run(:organisations, fn _repo, %{users: users} -> seed_organisations(users) end)
      |> Multi.run(:products, fn _repo, _ -> seed_products() end)
      |> Multi.run(:subscriptions, fn _repo, %{organisations: orgs} -> seed_subscriptions(orgs) end)
      |> Repo.transaction()

    summarise(results)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Individual seeders
  # ---------------------------------------------------------------------------

  defp seed_plans do
    plans = [
      %{slug: "starter", name: "Starter", price_cents: 0, currency: "USD"},
      %{slug: "growth", name: "Growth", price_cents: 4_900, currency: "USD"},
      %{slug: "enterprise", name: "Enterprise", price_cents: 29_900, currency: "USD"}
    ]

    results =
      Enum.map(plans, fn attrs ->
        case Repo.get_by(Billing.Plan, slug: attrs.slug) do
          nil ->
            {:ok, plan} = Billing.create_plan(attrs)
            {:created, plan}

          existing ->
            {:existing, existing}
        end
      end)

    {:ok, results}
  end

  defp seed_users do
    users = [
      %{email: "alice@example.dev", password: "SeedPassword1!", display_name: "Alice Admin", role: :admin},
      %{email: "bob@example.dev", password: "SeedPassword1!", display_name: "Bob Owner", role: :owner},
      %{email: "carol@example.dev", password: "SeedPassword1!", display_name: "Carol Member", role: :member}
    ]

    results =
      Enum.map(users, fn attrs ->
        case Repo.get_by(Accounts.User, email: attrs.email) do
          nil ->
            {:ok, user} = Accounts.register_user(attrs)
            {:created, user}

          existing ->
            {:existing, existing}
        end
      end)

    {:ok, results}
  end

  defp seed_organisations(user_results) do
    owner = find_user(user_results, "bob@example.dev")

    orgs = [
      %{name: "Acme Corp", subdomain: "acme", owner_id: owner.id, plan: :growth},
      %{name: "Globex Inc", subdomain: "globex", owner_id: owner.id, plan: :starter}
    ]

    results =
      Enum.map(orgs, fn attrs ->
        case Repo.get_by(Accounts.Organisation, subdomain: attrs.subdomain) do
          nil ->
            {:ok, org} = Accounts.create_organisation(attrs)
            {:created, org}

          existing ->
            {:existing, existing}
        end
      end)

    {:ok, results}
  end

  defp seed_products do
    products = [
      %{sku: "WIDGET-S", name: "Small Widget", price_cents: 999, currency: "USD", category: "widgets"},
      %{sku: "WIDGET-L", name: "Large Widget", price_cents: 1_999, currency: "USD", category: "widgets"},
      %{sku: "GADGET-1", name: "Premium Gadget", price_cents: 4_999, currency: "USD", category: "gadgets"}
    ]

    results =
      Enum.map(products, fn attrs ->
        case Repo.get_by(Catalog.Product, sku: attrs.sku) do
          nil ->
            {:ok, product} = Catalog.create_product(attrs)
            {:created, product}

          existing ->
            {:existing, existing}
        end
      end)

    {:ok, results}
  end

  defp seed_subscriptions(org_results) do
    orgs = Enum.flat_map(org_results, fn
      {:ok, results} -> Enum.filter_map(results, &match?({:created, _}, &1), &elem(&1, 1))
      _ -> []
    end)

    results =
      Enum.map(orgs, fn org ->
        case Repo.get_by(Billing.Subscription, organisation_id: org.id) do
          nil ->
            {:ok, sub} = Billing.create_subscription(%{
              organisation_id: org.id,
              plan: org.plan,
              status: :active
            })
            {:created, sub}

          existing ->
            {:existing, existing}
        end
      end)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_user(user_results, email) do
    {:ok, results} = user_results
    {_tag, user} = Enum.find(results, fn {_tag, u} -> u.email == email end)
    user
  end

  defp summarise(results) do
    Enum.each(results, fn {group, {:ok, items}} ->
      created = Enum.count(items, &match?({:created, _}, &1))
      existing = Enum.count(items, &match?({:existing, _}, &1))
      Logger.info("Seeded #{group}", created: created, existing: existing)
    end)
  end
end
```
