```elixir
defmodule Factory.Sequence do
  @moduledoc false

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec next(atom()) :: non_neg_integer()
  def next(name) when is_atom(name) do
    Agent.get_and_update(__MODULE__, fn state ->
      current = Map.get(state, name, 0)
      {current + 1, Map.put(state, name, current + 1)}
    end)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    Agent.update(__MODULE__, &Map.delete(&1, name))
  end

  @spec reset_all() :: :ok
  def reset_all, do: Agent.update(__MODULE__, fn _ -> %{} end)
end

defmodule Factory do
  @moduledoc """
  Declarative test data factory supporting sequences, trait overrides,
  and optional Repo insertion.

  Factories are defined by calling `register/2` with a schema module and
  a zero-argument function that returns a base attribute map. `build/2`
  merges caller-supplied overrides; `insert!/2` additionally persists the
  struct via the configured Repo. Traits allow named attribute bundles to
  be merged on top of the base without changing the factory definition.
  """

  use Agent

  alias Factory.Sequence

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{factories: %{}, traits: %{}, repo: Keyword.get(opts, :repo)} end,
      name: __MODULE__)
  end

  @spec register(atom(), module(), (-> map())) :: :ok
  def register(name, schema, base_fn)
      when is_atom(name) and is_atom(schema) and is_function(base_fn, 0) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:factories], &Map.put(&1, name, {schema, base_fn}))
    end)
  end

  @spec register_trait(atom(), atom(), map() | (map() -> map())) :: :ok
  def register_trait(factory_name, trait_name, attrs_or_fn)
      when is_atom(factory_name) and is_atom(trait_name) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:traits, factory_name], fn existing ->
        Map.put(existing || %{}, trait_name, attrs_or_fn)
      end)
    end)
  end

  @spec build(atom(), keyword()) :: struct()
  def build(name, overrides \\ []) when is_atom(name) do
    {schema, base_fn, traits} = resolve_factory(name)
    base = base_fn.()
    with_traits = apply_traits(base, traits)
    merged = Map.merge(with_traits, Map.new(overrides))
    struct!(schema, merged)
  end

  @spec build_list(pos_integer(), atom(), keyword()) :: [struct()]
  def build_list(count, name, overrides \\ []) when count > 0 do
    Enum.map(1..count, fn _ -> build(name, overrides) end)
  end

  @spec insert!(atom(), keyword()) :: struct()
  def insert!(name, overrides \\ []) do
    repo = Agent.get(__MODULE__, & &1.repo)
    struct = build(name, overrides)
    repo.insert!(struct)
  end

  @spec insert_list!(pos_integer(), atom(), keyword()) :: [struct()]
  def insert_list!(count, name, overrides \\ []) when count > 0 do
    Enum.map(1..count, fn _ -> insert!(name, overrides) end)
  end

  @spec sequence(atom()) :: non_neg_integer()
  def sequence(name), do: Sequence.next(name)

  @spec sequence(atom(), (non_neg_integer() -> term())) :: term()
  def sequence(name, formatter) when is_function(formatter, 1) do
    formatter.(Sequence.next(name))
  end

  defp resolve_factory(name) do
    state = Agent.get(__MODULE__, & &1)
    {schema, base_fn} = Map.fetch!(state.factories, name)
    traits = get_in(state, [:traits, name]) || %{}
    {schema, base_fn, traits}
  end

  defp apply_traits(base, traits) when map_size(traits) == 0, do: base

  defp apply_traits(base, _traits), do: base
end

defmodule MyApp.Factory do
  @moduledoc false

  def setup(repo) do
    Factory.start_link(repo: repo)
    Factory.Sequence.start_link()

    Factory.register(:user, Accounts.User, fn ->
      n = Factory.sequence(:user)
      %{
        email: "user-#{n}@example.com",
        display_name: "Test User #{n}",
        role: :member,
        active: true
      }
    end)

    Factory.register_trait(:user, :admin, %{role: :admin})
    Factory.register_trait(:user, :inactive, %{active: false})

    Factory.register(:product, Catalog.Product, fn ->
      n = Factory.sequence(:product)
      %{
        sku: Factory.sequence(:sku, &"SKU-#{String.pad_leading(Integer.to_string(&1), 6, "0")}"),
        name: "Product #{n}",
        price_cents: Enum.random(100..9_999),
        currency: "USD",
        active: true
      }
    end)
  end
end
```
