```elixir
defmodule Payments.GatewayRouter do
  @moduledoc """
  Routes payment requests to the appropriate payment gateway based on
  amount, currency, method, and merchant-level configuration.
  """

  require Logger

  @high_value_threshold 10_000
  @supported_currencies ~w(USD EUR GBP BRL)

  @type gateway :: :stripe | :braintree | :adyen | :pagseguro
  @type payment :: %{optional(atom()) => term()}

  @spec route(payment(), map()) :: {:ok, gateway()} | {:error, String.t()}
  def route(payment, merchant_config) do
    amount   = payment[:amount]
    currency = payment[:currency]
    method   = payment[:method]
    metadata = payment[:metadata]
    
    with :ok <- validate_currency(currency),
         :ok <- validate_amount(amount) do
      gateway = select_gateway(method, currency, merchant_config, amount)

      Logger.info("Payment routed",
        gateway: gateway,
        method: method,
        currency: currency,
        high_value: high_value?(amount),
        metadata: metadata
      )

      {:ok, gateway}
    end
  end

  @spec charge(gateway(), payment()) :: {:ok, map()} | {:error, term()}
  def charge(gateway, payment) do
    Logger.debug("Charging via #{gateway}", payment_ref: Map.get(payment, :reference))
    # Simulate gateway call – replace with real adapter in production
    {:ok, %{gateway: gateway, transaction_id: generate_ref(), status: :authorized}}
  end

  @spec validate_currency(String.t() | nil) :: :ok | {:error, String.t()}
  defp validate_currency(nil), do: {:error, "Currency is required"}

  defp validate_currency(currency) do
    if currency in @supported_currencies do
      :ok
    else
      {:error, "Unsupported currency: #{currency}"}
    end
  end

  @spec validate_amount(number() | nil) :: :ok | {:error, String.t()}
  defp validate_amount(nil), do: {:error, "Amount is required"}

  defp validate_amount(amount) when is_number(amount) and amount > 0, do: :ok

  defp validate_amount(amount),
    do: {:error, "Amount must be a positive number, got: #{inspect(amount)}"}

  @spec select_gateway(atom() | nil, String.t(), map(), number()) :: gateway()
  defp select_gateway(:credit_card, "BRL", _config, _amount), do: :pagseguro

  defp select_gateway(:credit_card, _currency, config, amount) do
    preferred = Map.get(config, :preferred_gateway, :stripe)

    if high_value?(amount) && preferred != :adyen do
      :adyen
    else
      preferred
    end
  end

  defp select_gateway(:paypal, _currency, _config, _amount), do: :braintree

  defp select_gateway(:bank_transfer, _currency, _config, _amount), do: :adyen

  defp select_gateway(_method, _currency, config, _amount) do
    Map.get(config, :fallback_gateway, :stripe)
  end

  @spec high_value?(number() | nil) :: boolean()
  defp high_value?(nil), do: false
  defp high_value?(amount), do: amount >= @high_value_threshold

  @spec generate_ref() :: String.t()
  defp generate_ref do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
```
