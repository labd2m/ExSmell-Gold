```elixir
defmodule DevTools.SeedBuilder do
  @moduledoc """
  Provides a composable DSL for building deterministic test and seed data.
  Each builder function accepts an optional override map so tests can
  specify only the fields they care about while defaults cover the rest.
  Builders are ordinary functions and carry no process state.
  """

  alias Accounts.User
  alias Store.Catalog.Product
  alias Billing.Invoice

  @doc "Builds a user attribute map with sensible defaults. Overrides any field."
  @spec user(map()) :: map()
  def user(overrides \ %{}) do
    suffix = unique_suffix()

    %{
      id: Ecto.UUID.generate(),
      email: "user_#{suffix}@example.test",
      display_name: "Test User #{suffix}",
      hashed_password: Bcrypt.hash_pwd_salt("Password123!"),
      role: "viewer",
      confirmed_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
    |> Map.merge(overrides)
  end

  @doc "Builds a product attribute map. Generates a unique SKU unless overridden."
  @spec product(map()) :: map()
  def product(overrides \ %{}) do
    suffix = unique_suffix()

    %{
      id: Ecto.UUID.generate(),
      name: "Test Product #{suffix}",
      sku: "SKU-#{suffix}",
      price_cents: 1_999,
      currency: "USD",
      active: true,
      category_id: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
    |> Map.merge(overrides)
  end

  @doc "Builds an invoice attribute map for `customer_id`."
  @spec invoice(String.t(), map()) :: map()
  def invoice(customer_id, overrides \ %{}) when is_binary(customer_id) do
    %{
      id: Ecto.UUID.generate(),
      customer_id: customer_id,
      status: "draft",
      currency: "USD",
      due_on: Date.add(Date.utc_today(), 30),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
    |> Map.merge(overrides)
  end

  @doc "Inserts a user into the database via `Repo.insert_all`, returning the attrs map."
  @spec insert_user(map()) :: map()
  def insert_user(overrides \ %{}) do
    attrs = user(overrides)
    MyApp.Repo.insert_all(User, [attrs], on_conflict: :nothing)
    attrs
  end

  @doc "Inserts a product into the database, returning the attrs map."
  @spec insert_product(map()) :: map()
  def insert_product(overrides \ %{}) do
    attrs = product(overrides)
    MyApp.Repo.insert_all(Product, [attrs], on_conflict: :nothing)
    attrs
  end

  @doc "Builds a list of `count` user attribute maps with sequential suffixes."
  @spec user_list(pos_integer(), map()) :: [map()]
  def user_list(count, overrides \ %{}) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _ -> user(overrides) end)
  end

  @doc "Builds a list of `count` product attribute maps."
  @spec product_list(pos_integer(), map()) :: [map()]
  def product_list(count, overrides \ %{}) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _ -> product(overrides) end)
  end

  defp unique_suffix do
    :erlang.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(6, "0")
  end
end
```
