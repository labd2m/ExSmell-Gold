```elixir
defmodule Billing.Invoice do
  @moduledoc """
  Pure functional module for computing invoice totals, tax breakdowns,
  and discount applications. Contains no process state or side effects.
  All monetary values are represented in cents (integer) to avoid
  floating-point precision issues.
  """

  @type line_item :: %{
          description: String.t(),
          quantity: pos_integer(),
          unit_price_cents: non_neg_integer(),
          tax_rate: float()
        }

  @type discount :: %{type: :flat | :percentage, value: non_neg_integer() | float()}

  @type invoice_summary :: %{
          subtotal_cents: non_neg_integer(),
          discount_cents: non_neg_integer(),
          taxable_cents: non_neg_integer(),
          tax_cents: non_neg_integer(),
          total_cents: non_neg_integer(),
          line_count: non_neg_integer()
        }

  @spec compute(
          [line_item()],
          discount() | nil,
          keyword()
        ) :: {:ok, invoice_summary()} | {:error, String.t()}
  def compute(line_items, discount \\ nil, opts \\ [])

  def compute(line_items, discount, opts)
      when is_list(line_items) and (is_map(discount) or is_nil(discount)) do
    currency = Keyword.get(opts, :currency, "USD")

    with :ok <- validate_line_items(line_items),
         :ok <- validate_discount(discount) do
      summary = build_summary(line_items, discount, currency)
      {:ok, summary}
    end
  end

  def compute(_line_items, _discount, _opts) do
    {:error, "line_items must be a list"}
  end

  @spec format_total(invoice_summary(), String.t()) :: String.t()
  def format_total(%{total_cents: total}, currency) when is_binary(currency) do
    major = div(total, 100)
    minor = rem(total, 100)
    "#{currency} #{major}.#{String.pad_leading(to_string(minor), 2, "0")}"
  end

  @spec validate_line_items([line_item()]) :: :ok | {:error, String.t()}
  defp validate_line_items([]), do: {:error, "invoice must contain at least one line item"}

  defp validate_line_items(items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, &validate_item/2)
  end

  @spec validate_item({line_item(), non_neg_integer()}, :ok) ::
          {:cont, :ok} | {:halt, {:error, String.t()}}
  defp validate_item({item, index}, :ok) do
    cond do
      not is_binary(item[:description]) or String.trim(item[:description]) == "" ->
        {:halt, {:error, "line item #{index}: description is required"}}

      not is_integer(item[:quantity]) or item[:quantity] <= 0 ->
        {:halt, {:error, "line item #{index}: quantity must be a positive integer"}}

      not is_integer(item[:unit_price_cents]) or item[:unit_price_cents] < 0 ->
        {:halt, {:error, "line item #{index}: unit_price_cents must be a non-negative integer"}}

      not is_float(item[:tax_rate]) or item[:tax_rate] < 0.0 or item[:tax_rate] > 1.0 ->
        {:halt, {:error, "line item #{index}: tax_rate must be a float between 0.0 and 1.0"}}

      true ->
        {:cont, :ok}
    end
  end

  @spec validate_discount(discount() | nil) :: :ok | {:error, String.t()}
  defp validate_discount(nil), do: :ok

  defp validate_discount(%{type: :flat, value: v}) when is_integer(v) and v >= 0, do: :ok
  defp validate_discount(%{type: :percentage, value: v}) when is_float(v) and v >= 0.0 and v <= 1.0, do: :ok
  defp validate_discount(_), do: {:error, "discount must have a valid type (:flat or :percentage) and value"}

  @spec build_summary([line_item()], discount() | nil, String.t()) :: invoice_summary()
  defp build_summary(items, discount, _currency) do
    subtotal = Enum.sum(Enum.map(items, &line_subtotal/1))
    tax = Enum.sum(Enum.map(items, &line_tax/1))
    discount_amount = compute_discount(subtotal, discount)
    taxable = max(subtotal - discount_amount, 0)

    %{
      subtotal_cents: subtotal,
      discount_cents: discount_amount,
      taxable_cents: taxable,
      tax_cents: tax,
      total_cents: max(taxable + tax, 0),
      line_count: length(items)
    }
  end

  @spec line_subtotal(line_item()) :: non_neg_integer()
  defp line_subtotal(%{quantity: q, unit_price_cents: p}), do: q * p

  @spec line_tax(line_item()) :: non_neg_integer()
  defp line_tax(%{quantity: q, unit_price_cents: p, tax_rate: r}) do
    round(q * p * r)
  end

  @spec compute_discount(non_neg_integer(), discount() | nil) :: non_neg_integer()
  defp compute_discount(_subtotal, nil), do: 0
  defp compute_discount(_subtotal, %{type: :flat, value: v}), do: v
  defp compute_discount(subtotal, %{type: :percentage, value: r}), do: round(subtotal * r)
end
```
