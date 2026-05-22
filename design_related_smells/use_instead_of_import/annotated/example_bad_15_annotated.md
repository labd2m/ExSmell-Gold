# Annotated Bad Example 15

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Billing.InvoiceGenerator`, `use Billing.CurrencyHelpers` directive
**Affected Functions:** `build/1`, `finalize/1`, `formatted_total/1`, `to_summary/1`
**Explanation:** `Billing.InvoiceGenerator` uses the `use` directive to depend on `Billing.CurrencyHelpers`, which silently injects `import Billing.CurrencyHelpers`, two hidden `alias` directives (`Billing.ExchangeRates` and `Billing.TaxRegistry`), and two module attributes (`@default_currency`, `@rounding_precision`). The client module only needs the arithmetic and formatting functions from `CurrencyHelpers`; a plain `import Billing.CurrencyHelpers` would have been sufficient and transparent. The hidden propagation of aliases and module attributes degrades readability and makes the module's actual dependencies invisible to a reader who does not inspect the library's `__using__/1` macro.

```elixir
defmodule Billing.CurrencyHelpers do
  @moduledoc """
  Utility functions for currency formatting and arithmetic operations
  used across the billing subsystem.
  """

  def format_amount(cents, currency \\ "USD") do
    symbol = currency_symbol(currency)
    value  = :erlang.float_to_binary(cents / 100, [{:decimals, 2}])
    "#{symbol}#{value}"
  end

  def parse_cents(string) when is_binary(string) do
    string
    |> String.replace(~r/[^\d.]/, "")
    |> String.to_float()
    |> Kernel.*(100)
    |> round()
  end

  def cents_to_float(cents) when is_integer(cents), do: cents / 100
  def float_to_cents(amount) when is_float(amount), do: round(amount * 100)

  def sum_line_items(items) do
    Enum.reduce(items, 0, fn %{total_cents: t}, acc -> acc + t end)
  end

  def apply_percentage(cents, pct) when is_integer(cents) and is_number(pct) do
    round(cents * pct / 100)
  end

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol("BRL"), do: "R$"
  defp currency_symbol(_),     do: ""

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 silently injects two aliases
  # (Billing.ExchangeRates and Billing.TaxRegistry) and two module attributes into
  # any module that calls `use Billing.CurrencyHelpers`. The client module has no
  # visibility into these injections without reading the library's internals.
  defmacro __using__(_opts) do
    quote do
      import Billing.CurrencyHelpers
      alias Billing.ExchangeRates
      alias Billing.TaxRegistry

      @default_currency   "USD"
      @rounding_precision 2
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Billing.ExchangeRates do
  @moduledoc "Stub for exchange-rate conversions."

  def convert(cents, from, to) when from == to, do: cents
  def convert(cents, "USD", "EUR"),             do: round(cents * 0.92)
  def convert(cents, "USD", "BRL"),             do: round(cents * 5.05)
  def convert(cents, "USD", "GBP"),             do: round(cents * 0.79)
  def convert(cents, _from, _to),               do: cents
end

defmodule Billing.TaxRegistry do
  @moduledoc "Stub for regional tax-rate lookups."

  def rate("US", :standard), do: 0.08
  def rate("DE", :standard), do: 0.19
  def rate("GB", :standard), do: 0.20
  def rate("BR", :standard), do: 0.12
  def rate(_, _),            do: 0.0
end

defmodule Billing.InvoiceGenerator do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Billing.CurrencyHelpers` expands the
  # __using__/1 macro, invisibly injecting aliases and module attributes that the
  # reader cannot discover without inspecting the library. A plain
  # `import Billing.CurrencyHelpers` would make all dependencies explicit.
  use Billing.CurrencyHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Responsible for building and finalising customer invoices,
  including line-item computation, tax application, and formatting.
  """

  defstruct [
    :id, :account_id, :line_items,
    :subtotal_cents, :tax_cents, :total_cents,
    :currency, :issued_at, :due_at, :status
  ]

  def build(params) do
    currency = params[:currency] || @default_currency
    items    = build_line_items(params[:items] || [], currency)
    subtotal = sum_line_items(items)
    tax      = compute_tax(subtotal, params[:country])
    total    = subtotal + tax

    %__MODULE__{
      id:             new_id(),
      account_id:     params[:account_id],
      line_items:     items,
      subtotal_cents: subtotal,
      tax_cents:      tax,
      total_cents:    total,
      currency:       currency,
      issued_at:      DateTime.utc_now(),
      due_at:         payment_due(params[:terms]),
      status:         :draft
    }
  end

  def finalize(%__MODULE__{status: :draft} = inv), do: {:ok, %{inv | status: :final}}
  def finalize(%__MODULE__{status: s}),             do: {:error, "Cannot finalise from #{s}"}

  def formatted_total(%__MODULE__{total_cents: t, currency: c}), do: format_amount(t, c)

  def to_summary(%__MODULE__{} = inv) do
    """
    Invoice ID : #{inv.id}
    Account    : #{inv.account_id}
    Subtotal   : #{format_amount(inv.subtotal_cents, inv.currency)}
    Tax        : #{format_amount(inv.tax_cents, inv.currency)}
    Total      : #{format_amount(inv.total_cents, inv.currency)}
    Status     : #{inv.status}
    Due        : #{Date.to_iso8601(DateTime.to_date(inv.due_at))}
    """
  end

  defp build_line_items(items, currency) do
    Enum.map(items, fn item ->
      unit      = float_to_cents(item[:unit_price])
      qty       = item[:quantity] || 1
      converted = ExchangeRates.convert(unit * qty, "USD", currency)
      %{description: item[:description], quantity: qty, unit_cents: unit, total_cents: converted}
    end)
  end

  defp compute_tax(subtotal, country) do
    rate = TaxRegistry.rate(country || "US", :standard)
    apply_percentage(subtotal, rate * 100)
  end

  defp payment_due(:net30), do: DateTime.add(DateTime.utc_now(), 30 * 86_400)
  defp payment_due(:net60), do: DateTime.add(DateTime.utc_now(), 60 * 86_400)
  defp payment_due(_),      do: DateTime.add(DateTime.utc_now(), 15 * 86_400)

  defp new_id, do: "INV-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
```
