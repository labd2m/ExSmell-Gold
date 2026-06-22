```elixir
defmodule Platform.Factory do
  @moduledoc """
  A test data factory that builds domain structs and Ecto records with
  sensible, deterministic defaults.

  `build/2` returns an in-memory struct; `insert/2` persists it via Repo.
  Overrides are deep-merged so callers can specify only the fields that
  matter for their test scenario.
  """

  alias Platform.Repo

  @doc "Builds an in-memory struct for `schema` with default values and `overrides`."
  @spec build(atom(), map() | keyword()) :: struct()
  def build(schema, overrides \\ %{}) when is_atom(schema) do
    attrs = schema |> defaults() |> deep_merge(to_map(overrides))
    struct!(schema, attrs)
  end

  @doc """
  Builds and inserts a record for `schema`. Returns the persisted struct.
  Raises on validation failure.
  """
  @spec insert!(atom(), map() | keyword()) :: struct()
  def insert!(schema, overrides \\ %{}) do
    attrs = schema |> defaults() |> deep_merge(to_map(overrides))
    changeset_fn = schema |> changeset_function()
    struct!(schema, %{}) |> changeset_fn.(attrs) |> Repo.insert!()
  end

  @doc "Inserts `count` records, returning a list."
  @spec insert_list!(atom(), pos_integer(), map() | keyword()) :: [struct()]
  def insert_list!(schema, count, overrides \\ %{}) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _ -> insert!(schema, overrides) end)
  end

  defp defaults(Platform.Accounts.User) do
    n = unique_int()
    %{
      email: "user_#{n}@example.com",
      name: "Test User #{n}",
      password_hash: Bcrypt.hash_pwd_salt("password123"),
      active: true,
      roles: [:member]
    }
  end

  defp defaults(Platform.Accounts.Workspace) do
    n = unique_int()
    %{name: "Workspace #{n}", plan: :free}
  end

  defp defaults(Platform.Billing.Invoice) do
    %{
      status: :unpaid,
      total_cents: 2_900,
      currency: "USD",
      due_date: Date.add(Date.utc_today(), 30)
    }
  end

  defp defaults(Platform.Billing.Plan) do
    n = unique_int()
    %{code: "plan_#{n}", name: "Plan #{n}", price_cents: 0, max_seats: 1, features: []}
  end

  defp defaults(Platform.Catalog.Product) do
    n = unique_int()
    %{
      sku: "SKU-#{String.pad_leading(to_string(n), 6, "0")}",
      name: "Product #{n}",
      price_cents: 999,
      currency: "USD",
      status: :draft,
      stock_quantity: 100
    }
  end

  defp defaults(schema) do
    raise ArgumentError, "No factory defaults defined for #{inspect(schema)}. " <>
      "Add a `defp defaults(#{inspect(schema)})` clause to #{inspect(__MODULE__)}."
  end

  defp changeset_function(schema) do
    cond do
      function_exported?(schema, :changeset, 2) -> &schema.changeset/2
      function_exported?(schema, :creation_changeset, 2) -> &schema.creation_changeset/2
      true -> fn struct, attrs -> Ecto.Changeset.cast(struct, attrs, Map.keys(attrs)) end
    end
  end

  defp deep_merge(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides, fn _key, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  defp to_map(overrides) when is_map(overrides), do: overrides
  defp to_map(overrides) when is_list(overrides), do: Map.new(overrides)

  defp unique_int do
    System.unique_integer([:positive])
  end
end
```
