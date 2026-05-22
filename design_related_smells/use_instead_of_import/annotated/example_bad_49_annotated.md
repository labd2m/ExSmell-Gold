# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `OrderProcessor` module, top-level directive
- **Affected function(s):** `process/1`, `apply_promotions/2`, `finalize/2`
- **Short explanation:** `OrderProcessor` calls `use PipelineHelpers` to get step-execution and error-aggregation utilities. The `__using__/1` macro injects an `import` of `ErrorCollector` into the caller, giving `OrderProcessor` access to `collect/1`, `merge/2`, and `first_error/1` without any visible declaration. This hidden propagation makes `OrderProcessor` harder to understand in isolation. A plain `import PipelineHelpers` (combined with an explicit `import ErrorCollector` if needed) would be transparent.

---

```elixir
defmodule ErrorCollector do
  def collect(results) do
    Enum.flat_map(results, fn
      {:error, msg} when is_binary(msg) -> [msg]
      {:error, msgs} when is_list(msgs) -> msgs
      _                                 -> []
    end)
  end

  def merge(errors_a, errors_b), do: errors_a ++ errors_b

  def first_error([]),        do: nil
  def first_error([h | _]),   do: h

  def any_errors?(results) do
    Enum.any?(results, &match?({:error, _}, &1))
  end
end

defmodule PipelineHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 silently injects
      # VALIDATION: `import ErrorCollector` into OrderProcessor. The functions
      # VALIDATION: collect/1, merge/2, first_error/1, and any_errors?/1 become
      # VALIDATION: available in OrderProcessor with no visible import statement.
      # VALIDATION: This hidden dependency propagation reduces readability and can
      # VALIDATION: lead to unexpected name conflicts. `import PipelineHelpers`
      # VALIDATION: at the call site would be the appropriate, explicit alternative.
      import ErrorCollector
      # VALIDATION: SMELL END

      def run_steps(value, steps) do
        Enum.reduce_while(steps, {:ok, value}, fn step, {:ok, acc} ->
          case step.(acc) do
            {:ok, new_val}    -> {:cont, {:ok, new_val}}
            {:error, _} = err -> {:halt, err}
          end
        end)
      end

      def run_all_steps(value, steps) do
        {results, final} =
          Enum.reduce(steps, {[], value}, fn step, {errs, acc} ->
            case step.(acc) do
              {:ok, new_val}    -> {errs, new_val}
              {:error, msg}     -> {[msg | errs], acc}
            end
          end)

        if results == [], do: {:ok, final}, else: {:error, Enum.reverse(results)}
      end
    end
  end
end

defmodule OrderProcessor do
  use PipelineHelpers

  @tax_rate       0.08
  @max_line_items 50

  def process(order) do
    steps = [
      &validate_items/1,
      &validate_customer/1,
      &apply_inventory_check/1
    ]

    with {:ok, validated} <- run_steps(order, steps),
         {:ok, priced}    <- price_order(validated),
         {:ok, promoted}  <- apply_promotions(priced, order.promotion_codes || []) do
      finalize(promoted, order)
    end
  end

  def apply_promotions(order, codes) do
    results =
      Enum.map(codes, fn code ->
        lookup_promotion(code, order)
      end)

    if any_errors?(results) do
      errors = collect(results)
      {:error, errors}
    else
      discounts = Enum.map(results, fn {:ok, pct} -> pct end)
      total_discount = Enum.sum(discounts) |> min(0.5)
      {:ok, Map.put(order, :discount, total_discount)}
    end
  end

  def finalize(order, original) do
    errors =
      collect([
        check_payment_method(original.payment_method),
        check_shipping_address(original.shipping_address)
      ])

    if errors == [] do
      subtotal = order.subtotal
      tax      = Float.round(subtotal * @tax_rate, 2)
      total    = Float.round(subtotal * (1 - (order[:discount] || 0)) + tax, 2)

      {:ok, %{
        id:               "ord_#{:erlang.unique_integer([:positive])}",
        customer_id:      original.customer_id,
        line_items:       order.line_items,
        subtotal:         subtotal,
        discount:         order[:discount] || 0.0,
        tax:              tax,
        total:            total,
        payment_method:   original.payment_method,
        shipping_address: original.shipping_address,
        status:           :confirmed,
        placed_at:        DateTime.utc_now()
      }}
    else
      {:error, errors}
    end
  end

  defp validate_items(order) do
    cond do
      length(order.line_items) == 0           -> {:error, "Order must have at least one item"}
      length(order.line_items) > @max_line_items -> {:error, "Order exceeds max line items"}
      true                                    -> {:ok, order}
    end
  end

  defp validate_customer(order) do
    if is_binary(order.customer_id) and byte_size(order.customer_id) > 0,
      do: {:ok, order},
      else: {:error, "Invalid customer ID"}
  end

  defp apply_inventory_check(order) do
    {:ok, order}
  end

  defp price_order(order) do
    subtotal = Enum.sum(Enum.map(order.line_items, fn i -> i.qty * i.unit_price end))
    {:ok, Map.put(order, :subtotal, Float.round(subtotal, 2))}
  end

  defp lookup_promotion("SAVE10", _order), do: {:ok, 0.10}
  defp lookup_promotion("SAVE20", _order), do: {:ok, 0.20}
  defp lookup_promotion(code, _order),     do: {:error, "Unknown promotion: #{code}"}

  defp check_payment_method(nil), do: {:error, "Payment method is required"}
  defp check_payment_method(_),   do: :ok

  defp check_shipping_address(nil), do: {:error, "Shipping address is required"}
  defp check_shipping_address(_),   do: :ok
end
```
