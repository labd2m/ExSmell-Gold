# Annotated Example 07 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defgateway/2` inside `Payments.GatewayDSL`
- **Affected function(s):** `defgateway/2`
- **Short explanation:** The macro inlines a lengthy block—currency list validation, supported operations check, webhook secret format check, timeout bounds check, retry policy validation, and attribute registration—inside the quote. Every gateway declaration re-expands and re-compiles this whole block instead of calling a single helper function.

---

```elixir
defmodule Payments.GatewayDSL do
  @moduledoc """
  Compile-time DSL for registering payment gateway configurations.

  Each gateway declaration binds an adapter module to a set of supported
  currencies, operations, retry policies, and timeouts. All parameters
  are validated at compile time.
  """

  @supported_operations [:charge, :refund, :capture, :void, :partial_refund]
  @supported_currencies [:usd, :eur, :gbp, :brl, :cad, :aud]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defgateway/2 places all validation
  # VALIDATION: logic—including iteration over currencies and operations—
  # VALIDATION: directly inside the quoted block. Every use of this macro
  # VALIDATION: causes the compiler to expand and compile this large body
  # VALIDATION: of code again, instead of delegating to a helper function
  # VALIDATION: that would be compiled once and called at runtime.
  defmacro defgateway(gateway_name, opts) do
    quote do
      gw   = unquote(gateway_name)
      opts = unquote(opts)

      unless is_atom(gw) do
        raise ArgumentError,
              "gateway name must be an atom, got: #{inspect(gw)}"
      end

      adapter = Keyword.fetch!(opts, :adapter)

      unless is_atom(adapter) do
        raise ArgumentError,
              "gateway #{inspect(gw)} :adapter must be a module atom"
      end

      currencies = Keyword.get(opts, :currencies, [:usd])

      unless is_list(currencies) and currencies != [] do
        raise ArgumentError,
              "gateway #{inspect(gw)} :currencies must be a non-empty list"
      end

      Enum.each(currencies, fn c ->
        unless c in unquote(@supported_currencies) do
          raise ArgumentError,
                "gateway #{inspect(gw)} unsupported currency #{inspect(c)}. " <>
                  "Supported: #{inspect(unquote(@supported_currencies))}"
        end
      end)

      operations = Keyword.get(opts, :operations, [:charge, :refund])

      Enum.each(operations, fn op ->
        unless op in unquote(@supported_operations) do
          raise ArgumentError,
                "gateway #{inspect(gw)} unsupported operation #{inspect(op)}. " <>
                  "Supported: #{inspect(unquote(@supported_operations))}"
        end
      end)

      timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)

      unless is_integer(timeout_ms) and timeout_ms >= 1_000 and timeout_ms <= 60_000 do
        raise ArgumentError,
              "gateway #{inspect(gw)} :timeout_ms must be between 1_000 and 60_000"
      end

      max_retries = Keyword.get(opts, :max_retries, 2)

      unless is_integer(max_retries) and max_retries >= 0 do
        raise ArgumentError,
              "gateway #{inspect(gw)} :max_retries must be a non-negative integer"
      end

      webhook_secret = Keyword.get(opts, :webhook_secret)

      if webhook_secret != nil do
        unless is_binary(webhook_secret) and byte_size(webhook_secret) >= 16 do
          raise ArgumentError,
                "gateway #{inspect(gw)} :webhook_secret must be a binary of at least 16 bytes"
        end
      end

      sandbox = Keyword.get(opts, :sandbox, false)

      unless is_boolean(sandbox) do
        raise ArgumentError,
              "gateway #{inspect(gw)} :sandbox must be a boolean"
      end

      @payment_gateways %{
        name:           gw,
        adapter:        adapter,
        currencies:     currencies,
        operations:     operations,
        timeout_ms:     timeout_ms,
        max_retries:    max_retries,
        webhook_secret: webhook_secret,
        sandbox:        sandbox
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Payments.GatewayDSL, only: [defgateway: 2]
      Module.register_attribute(__MODULE__, :payment_gateways, accumulate: true)
      @before_compile Payments.GatewayDSL
    end
  end

  defmacro __before_compile__(env) do
    gateways = Module.get_attribute(env.module, :payment_gateways)

    quote do
      def gateways, do: unquote(Macro.escape(gateways))

      def gateway(name) do
        Enum.find(gateways(), &(&1.name == name))
      end

      def supports_currency?(gateway_name, currency) do
        case gateway(gateway_name) do
          nil -> false
          gw  -> currency in gw.currencies
        end
      end

      def supports_operation?(gateway_name, operation) do
        case gateway(gateway_name) do
          nil -> false
          gw  -> operation in gw.operations
        end
      end
    end
  end
end

defmodule Payments.AppGateways do
  use Payments.GatewayDSL

  defgateway(:stripe,
    adapter: Payments.Adapters.Stripe,
    currencies: [:usd, :eur, :gbp, :cad, :aud],
    operations: [:charge, :refund, :capture, :void, :partial_refund],
    timeout_ms: 15_000,
    max_retries: 3,
    webhook_secret: "whsec_testkey_1234567890abcdef",
    sandbox: false
  )

  defgateway(:paypal,
    adapter: Payments.Adapters.PayPal,
    currencies: [:usd, :eur, :gbp],
    operations: [:charge, :refund, :partial_refund],
    timeout_ms: 20_000,
    max_retries: 2,
    sandbox: false
  )

  defgateway(:braintree,
    adapter: Payments.Adapters.Braintree,
    currencies: [:usd, :brl],
    operations: [:charge, :refund, :void],
    timeout_ms: 12_000,
    max_retries: 2,
    sandbox: true
  )

  defgateway(:adyen,
    adapter: Payments.Adapters.Adyen,
    currencies: [:usd, :eur, :gbp, :brl],
    operations: [:charge, :refund, :capture, :void],
    timeout_ms: 10_000,
    max_retries: 3,
    sandbox: false
  )
end
```
