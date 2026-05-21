```elixir
defmodule MyApp.Inventory.CatalogueRegistry do
  @moduledoc """
  DSL for declaring product item types in the warehouse inventory catalogue.

  Each `item_type/2` call registers a SKU category with its unit of measure,
  restocking threshold, and storage constraints.

  ## Usage

      defmodule MyApp.Inventory.Catalogue do
        use MyApp.Inventory.CatalogueRegistry

        item_type :raw_steel,       unit: :kg,    reorder_threshold: 500,  max_stock: 50_000
        item_type :packaging_box,   unit: :unit,  reorder_threshold: 200,  max_stock: 10_000
        item_type :industrial_oil,  unit: :litre, reorder_threshold: 100,  max_stock: 5_000, hazardous: true
        item_type :fastener_m8,     unit: :unit,  reorder_threshold: 1000, max_stock: 100_000
        item_type :insulation_foam, unit: :m2,    reorder_threshold: 50,   max_stock: 2_000
      end
  """

  @valid_units [:unit, :kg, :g, :litre, :ml, :m, :m2, :m3, :box, :pallet]

  defmacro __using__(_opts) do
    quote do
      import MyApp.Inventory.CatalogueRegistry, only: [item_type: 2]
      Module.register_attribute(__MODULE__, :item_types, accumulate: true)
      @before_compile MyApp.Inventory.CatalogueRegistry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns all registered item types as a list of config maps."
      def all_item_types do
        Enum.map(@item_types, fn {name, cfg} -> Map.put(cfg, :name, name) end)
      end

      @doc "Returns the config map for a given item type name, or `nil`."
      def config_for(name) do
        Enum.find_value(@item_types, fn {n, cfg} ->
          if n == name, do: Map.put(cfg, :name, n)
        end)
      end

      @doc "Returns item types flagged as hazardous materials."
      def hazardous_types do
        @item_types
        |> Enum.filter(fn {_name, cfg} -> Map.get(cfg, :hazardous, false) end)
        |> Enum.map(&elem(&1, 0))
      end
    end
  end

  defmacro item_type(name, opts) do
    quote do
      unless is_atom(unquote(name)) do
        raise ArgumentError,
              "item_type/2: name must be an atom, got: #{inspect(unquote(name))}"
      end

      unit              = Keyword.get(unquote(opts), :unit, :unit)
      reorder_threshold = Keyword.get(unquote(opts), :reorder_threshold, 0)
      max_stock         = Keyword.get(unquote(opts), :max_stock)
      hazardous         = Keyword.get(unquote(opts), :hazardous, false)

      unless unit in unquote(@valid_units) do
        raise ArgumentError,
              "item_type/2 #{inspect(unquote(name))}: unknown unit #{inspect(unit)}. " <>
                "Valid units: #{inspect(unquote(@valid_units))}"
      end

      unless is_integer(reorder_threshold) and reorder_threshold >= 0 do
        raise ArgumentError,
              "item_type/2 #{inspect(unquote(name))}: :reorder_threshold must be a " <>
                "non-negative integer, got: #{inspect(reorder_threshold)}"
      end

      unless is_nil(max_stock) or (is_integer(max_stock) and max_stock > reorder_threshold) do
        raise ArgumentError,
              "item_type/2 #{inspect(unquote(name))}: :max_stock must be an integer greater " <>
                "than :reorder_threshold (#{reorder_threshold}), got: #{inspect(max_stock)}"
      end

      unless is_boolean(hazardous) do
        raise ArgumentError,
              "item_type/2 #{inspect(unquote(name))}: :hazardous must be a boolean, " <>
                "got: #{inspect(hazardous)}"
      end

      @item_types {unquote(name),
                   %{unit: unit, reorder_threshold: reorder_threshold,
                     max_stock: max_stock, hazardous: hazardous}}

      @doc "Returns the unit of measure for #{unquote(name)}."
      def unquote(:"item_#{name}_unit")(), do: unit

      @doc "Returns the reorder threshold quantity for #{unquote(name)}."
      def unquote(:"item_#{name}_reorder_threshold")(), do: reorder_threshold

      @doc """
      Returns `true` when `quantity` is within storable limits for #{unquote(name)}.
      """
      def unquote(:"item_#{name}_storable?")(quantity) do
        is_integer(quantity) and quantity >= 0 and
          (is_nil(max_stock) or quantity <= max_stock)
      end
    end
  end

  @doc "Returns all recognised units of measure."
  def valid_units, do: @valid_units
end
```
