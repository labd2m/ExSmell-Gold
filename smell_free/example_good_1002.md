```elixir
defmodule MyApp.Payments.GatewayRouter do
  @moduledoc """
  Routes payment charges to one of several gateway adapters based on
  the currency, card type, and customer region. The routing table is
  defined as module attributes so that routing decisions are visible at
  a glance and can be changed without touching dispatching logic.

  Each adapter implements the `MyApp.Payments.GatewayAdapter` behaviour.
  Fallback routing ensures that even when the preferred gateway is
  unavailable a secondary gateway handles the charge.
  """

  alias MyApp.Payments.GatewayAdapter

  @primary_routes [
    {%{currency: "EUR"}, MyApp.Payments.Adapters.Stripe},
    {%{currency: "GBP"}, MyApp.Payments.Adapters.Stripe},
    {%{currency: "USD", region: "US"}, MyApp.Payments.Adapters.Stripe},
    {%{currency: "BRL"}, MyApp.Payments.Adapters.PagSeguro},
    {%{currency: "INR"}, MyApp.Payments.Adapters.Razorpay}
  ]

  @fallback_gateway MyApp.Payments.Adapters.Stripe

  @type charge_params :: %{
          required(:amount_cents) => pos_integer(),
          required(:currency) => String.t(),
          required(:payment_method_id) => String.t(),
          optional(:customer_id) => String.t(),
          optional(:region) => String.t(),
          optional(:card_type) => String.t(),
          optional(:idempotency_key) => String.t()
        }

  @doc """
  Charges `params` through the appropriate gateway adapter.
  Attempts the primary gateway first; if it raises or returns a
  transient error, retries with the fallback gateway.
  """
  @spec charge(charge_params()) :: {:ok, String.t()} | {:error, term()}
  def charge(%{} = params) do
    gateway = select_gateway(params)

    case gateway.charge(params) do
      {:ok, _} = success ->
        success

      {:error, :gateway_unavailable} when gateway != @fallback_gateway ->
        require Logger
        Logger.warning("gateway_primary_unavailable", gateway: gateway, currency: params.currency)
        @fallback_gateway.charge(params)

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns the gateway module that would be used for `params`."
  @spec select_gateway(charge_params()) :: module()
  def select_gateway(params) do
    Enum.find_value(@primary_routes, @fallback_gateway, fn {criteria, adapter} ->
      if matches?(criteria, params), do: adapter
    end)
  end

  @spec matches?(map(), charge_params()) :: boolean()
  defp matches?(criteria, params) do
    Enum.all?(criteria, fn {key, value} ->
      Map.get(params, key) == value
    end)
  end
end

defmodule MyApp.Payments.GatewayAdapter do
  @moduledoc "Behaviour contract for payment gateway adapter modules."

  @callback charge(MyApp.Payments.GatewayRouter.charge_params()) ::
              {:ok, String.t()} | {:error, term()}

  @callback refund(String.t(), pos_integer()) :: :ok | {:error, term()}

  @callback capture(String.t()) :: {:ok, String.t()} | {:error, term()}
end
```
