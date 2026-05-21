# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro stock_rule/2` inside `MyApp.Inventory.StockPolicy`
- **Affected function(s):** `stock_rule/2` macro
- **Short explanation:** The macro inlines a large `quote` block with warehouse code validation, threshold checks, action enumeration, escalation path validation, deduplication guards, and struct assembly at every call site. A policy module with many SKU rules will have this entire block duplicated in the compiled bytecode for each call, slowing compilation.

---

```elixir
defmodule MyApp.Inventory.StockPolicy do
  @moduledoc """
  DSL for declaring per-SKU restocking rules within a warehouse policy module.

  Example:

      defmodule MyApp.Inventory.WarehouseGRU do
        use MyApp.Inventory.StockPolicy

        stock_rule "SKU-001",
          min_qty: 50,
          max_qty: 500,
          reorder_qty: 200,
          on_breach: :alert,
          warehouse: "GRU"

        stock_rule "SKU-002",
          min_qty: 10,
          max_qty: 100,
          reorder_qty: 50,
          on_breach: :auto_reorder,
          warehouse: "GRU"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Inventory.StockPolicy, only: [stock_rule: 2]
      Module.register_attribute(__MODULE__, :stock_rules, accumulate: true)
      @before_compile MyApp.Inventory.StockPolicy
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def stock_rules, do: @stock_rules

      def rule_for(sku) do
        Enum.find(@stock_rules, fn r -> r.sku == sku end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to stock_rule/2 causes the
  # VALIDATION: Elixir compiler to expand this entire block inline: SKU string
  # VALIDATION: validation, warehouse code format checks, numeric threshold
  # VALIDATION: ordering assertions, on_breach action enumeration, escalation
  # VALIDATION: option checks, deduplication guard, and struct construction.
  # VALIDATION: Dozens of SKU rules in a single module means dozens of full
  # VALIDATION: expansions, rather than delegating to a plain function.
  defmacro stock_rule(sku, opts) do
    quote do
      sku  = unquote(sku)
      opts = unquote(opts)

      unless is_binary(sku) and byte_size(sku) > 0 do
        raise ArgumentError,
              "stock_rule/2: SKU must be a non-empty string, got #{inspect(sku)}"
      end

      warehouse = Keyword.fetch!(opts, :warehouse)

      unless is_binary(warehouse) and String.match?(warehouse, ~r/^[A-Z]{3}$/) do
        raise ArgumentError,
              "stock_rule/2: :warehouse must be a 3-letter uppercase IATA code, " <>
                "got #{inspect(warehouse)}"
      end

      min_qty    = Keyword.fetch!(opts, :min_qty)
      max_qty    = Keyword.fetch!(opts, :max_qty)
      reorder_qty = Keyword.get(opts, :reorder_qty, min_qty * 2)

      unless is_integer(min_qty) and min_qty >= 0 do
        raise ArgumentError,
              "stock_rule/2: :min_qty must be a non-negative integer, got #{inspect(min_qty)}"
      end

      unless is_integer(max_qty) and max_qty > 0 do
        raise ArgumentError,
              "stock_rule/2: :max_qty must be a positive integer, got #{inspect(max_qty)}"
      end

      unless min_qty < max_qty do
        raise ArgumentError,
              "stock_rule/2: :min_qty (#{min_qty}) must be less than :max_qty (#{max_qty})"
      end

      unless is_integer(reorder_qty) and reorder_qty > 0 and reorder_qty <= max_qty do
        raise ArgumentError,
              "stock_rule/2: :reorder_qty must be a positive integer <= :max_qty, " <>
                "got #{inspect(reorder_qty)}"
      end

      valid_actions = [:alert, :auto_reorder, :suspend_sales, :notify_manager]
      on_breach = Keyword.get(opts, :on_breach, :alert)

      unless on_breach in valid_actions do
        raise ArgumentError,
              "stock_rule/2: :on_breach must be one of #{inspect(valid_actions)}, " <>
                "got #{inspect(on_breach)}"
      end

      existing = Module.get_attribute(__MODULE__, :stock_rules)

      if Enum.any?(existing, fn r -> r.sku == sku and r.warehouse == warehouse end) do
        raise ArgumentError,
              "stock_rule/2: duplicate rule for SKU #{inspect(sku)} in warehouse " <>
                "#{inspect(warehouse)} within #{inspect(__MODULE__)}"
      end

      rule = %{
        sku:         sku,
        warehouse:   warehouse,
        min_qty:     min_qty,
        max_qty:     max_qty,
        reorder_qty: reorder_qty,
        on_breach:   on_breach
      }

      @stock_rules rule
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Evaluates current inventory levels against registered rules and returns
  a list of triggered breach events.
  """
  @spec evaluate(module(), %{String.t() => integer()}) :: [{map(), :low | :high}]
  def evaluate(policy_module, current_stock) do
    policy_module.stock_rules()
    |> Enum.flat_map(fn rule ->
      qty = Map.get(current_stock, rule.sku, 0)

      cond do
        qty < rule.min_qty -> [{rule, :low}]
        qty > rule.max_qty -> [{rule, :high}]
        true               -> []
      end
    end)
  end

  @doc """
  Returns the reorder quantity for the given SKU according to the policy
  registered in `policy_module`.
  """
  @spec reorder_quantity(module(), String.t()) :: integer() | nil
  def reorder_quantity(policy_module, sku) do
    case policy_module.rule_for(sku) do
      nil  -> nil
      rule -> rule.reorder_qty
    end
  end
end
```
