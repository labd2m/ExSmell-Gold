```elixir
defmodule Billing.InvoiceTypes do
  @moduledoc """
  DSL for declaring invoice types used across the billing subsystem.
  Each invoice type carries its own validation rules, allowed transitions,
  and fee structure, all registered at compile time.
  """

  @invoice_types []

  defmacro define_invoice_type(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "invoice type name must be an atom, got: #{inspect(name)}"
      end

      label = Keyword.get(opts, :label)

      unless is_binary(label) do
        raise ArgumentError,
              "invoice type #{inspect(name)} must have a binary :label"
      end

      allowed_transitions = Keyword.get(opts, :transitions, [])

      unless is_list(allowed_transitions) do
        raise ArgumentError,
              "invoice type #{inspect(name)} :transitions must be a list"
      end

      Enum.each(allowed_transitions, fn t ->
        unless is_atom(t) do
          raise ArgumentError,
                "each transition for #{inspect(name)} must be an atom, got: #{inspect(t)}"
        end
      end)

      fee_pct = Keyword.get(opts, :fee_percentage, 0)

      unless is_number(fee_pct) and fee_pct >= 0 and fee_pct <= 100 do
        raise ArgumentError,
              "invoice type #{inspect(name)} :fee_percentage must be a number between 0 and 100"
      end

      currency = Keyword.get(opts, :currency, :usd)

      unless currency in [:usd, :eur, :brl, :gbp] do
        raise ArgumentError,
              "invoice type #{inspect(name)} :currency must be one of [:usd, :eur, :brl, :gbp]"
      end

      taxable = Keyword.get(opts, :taxable, false)

      unless is_boolean(taxable) do
        raise ArgumentError,
              "invoice type #{inspect(name)} :taxable must be a boolean"
      end

      @invoice_types {name,
                      %{
                        label: label,
                        transitions: allowed_transitions,
                        fee_percentage: fee_pct,
                        currency: currency,
                        taxable: taxable
                      }}
    end
  end

  defmacro __using__(_opts) do
    quote do
      import Billing.InvoiceTypes, only: [define_invoice_type: 2]
      Module.register_attribute(__MODULE__, :invoice_types, accumulate: true)

      @before_compile Billing.InvoiceTypes
    end
  end

  defmacro __before_compile__(env) do
    types = Module.get_attribute(env.module, :invoice_types)

    quote do
      def all_invoice_types, do: unquote(Macro.escape(types))

      def invoice_type(name) do
        Enum.find(all_invoice_types(), fn {n, _} -> n == name end)
      end
    end
  end
end

defmodule Billing.StandardInvoices do
  use Billing.InvoiceTypes

  define_invoice_type(:standard,
    label: "Standard Invoice",
    transitions: [:draft, :pending, :paid, :void],
    fee_percentage: 2.5,
    currency: :usd,
    taxable: true
  )

  define_invoice_type(:credit_note,
    label: "Credit Note",
    transitions: [:draft, :applied, :void],
    fee_percentage: 0,
    currency: :usd,
    taxable: false
  )

  define_invoice_type(:proforma,
    label: "Pro-Forma Invoice",
    transitions: [:draft, :sent, :converted, :void],
    fee_percentage: 0,
    currency: :eur,
    taxable: true
  )

  define_invoice_type(:recurring,
    label: "Recurring Invoice",
    transitions: [:scheduled, :pending, :paid, :failed, :void],
    fee_percentage: 1.5,
    currency: :usd,
    taxable: true
  )
end
```
