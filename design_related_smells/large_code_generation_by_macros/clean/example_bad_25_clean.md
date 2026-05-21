```elixir
defmodule MyApp.Payments.GatewayRegistry do
  @moduledoc """
  DSL for registering payment gateway adapters with their configurations.

  Example:

      defmodule MyApp.Payments.ProcessorConfig do
        use MyApp.Payments.GatewayRegistry

        payment_gateway MyApp.Gateways.Stripe,
          currencies:   ~w[USD EUR GBP BRL],
          fee_percent:  2.9,
          fee_fixed_cents: 30,
          supports_refunds: true

        payment_gateway MyApp.Gateways.PayPal,
          currencies:      ~w[USD EUR BRL],
          fee_percent:     3.5,
          fee_fixed_cents: 0,
          supports_refunds: true
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Payments.GatewayRegistry, only: [payment_gateway: 2]
      Module.register_attribute(__MODULE__, :gateways, accumulate: true)
      @before_compile MyApp.Payments.GatewayRegistry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def gateways, do: @gateways

      def gateway_for_currency(currency) do
        Enum.find(@gateways, fn gw ->
          currency in gw.currencies
        end)
      end
    end
  end

  defmacro payment_gateway(module, opts) do
    quote do
      module = unquote(module)
      opts   = unquote(opts)

      unless is_atom(module) do
        raise ArgumentError,
              "payment_gateway/2: first argument must be a module atom, got #{inspect(module)}"
      end

      :ok = Code.ensure_compiled!(module)

      unless function_exported?(module, :charge, 2) do
        raise ArgumentError,
              "payment_gateway/2: #{inspect(module)} must export charge/2"
      end

      unless function_exported?(module, :refund, 2) do
        raise ArgumentError,
              "payment_gateway/2: #{inspect(module)} must export refund/2"
      end

      currencies = Keyword.get(opts, :currencies, [])

      unless is_list(currencies) and Enum.all?(currencies, &is_binary/1) do
        raise ArgumentError,
              "payment_gateway/2: :currencies must be a list of currency code strings, " <>
                "got #{inspect(currencies)}"
      end

      if Enum.empty?(currencies) do
        raise ArgumentError,
              "payment_gateway/2: :currencies must not be empty for #{inspect(module)}"
      end

      fee_percent = Keyword.get(opts, :fee_percent, 0.0)

      unless is_float(fee_percent) and fee_percent >= 0.0 and fee_percent < 100.0 do
        raise ArgumentError,
              "payment_gateway/2: :fee_percent must be a float in [0, 100), " <>
                "got #{inspect(fee_percent)}"
      end

      fee_fixed = Keyword.get(opts, :fee_fixed_cents, 0)

      unless is_integer(fee_fixed) and fee_fixed >= 0 do
        raise ArgumentError,
              "payment_gateway/2: :fee_fixed_cents must be a non-negative integer, " <>
                "got #{inspect(fee_fixed)}"
      end

      supports_refunds = Keyword.get(opts, :supports_refunds, false)

      unless is_boolean(supports_refunds) do
        raise ArgumentError,
              "payment_gateway/2: :supports_refunds must be a boolean, " <>
                "got #{inspect(supports_refunds)}"
      end

      existing = Module.get_attribute(__MODULE__, :gateways)

      if Enum.any?(existing, fn gw -> gw.module == module end) do
        raise ArgumentError,
              "payment_gateway/2: #{inspect(module)} is already registered in #{inspect(__MODULE__)}"
      end

      gateway = %{
        module:           module,
        currencies:       currencies,
        fee_percent:      fee_percent,
        fee_fixed_cents:  fee_fixed,
        supports_refunds: supports_refunds
      }

      @gateways gateway
    end
  end

  @doc """
  Computes the total fee for a given charge amount (in cents) using the
  registered fee structure of the provided gateway config map.
  """
  @spec compute_fee(map(), pos_integer()) :: integer()
  def compute_fee(gateway, amount_cents) do
    variable = round(amount_cents * gateway.fee_percent / 100.0)
    variable + gateway.fee_fixed_cents
  end

  @doc """
  Returns all currencies supported across all registered gateways in
  `config_module`.
  """
  @spec supported_currencies(module()) :: [String.t()]
  def supported_currencies(config_module) do
    config_module.gateways()
    |> Enum.flat_map(& &1.currencies)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
```
