```elixir
defmodule Payments.StripeEventDispatcher do
  @moduledoc """
  Routes inbound Stripe webhook events to typed handler modules.
  Each event type maps to a dedicated handler that receives the
  fully decoded event struct, keeping the dispatch layer thin and
  the business logic isolated per event.
  """

  alias Payments.StripeHandlers.{
    PaymentIntentHandler,
    SubscriptionHandler,
    InvoiceHandler,
    CustomerHandler
  }

  @type stripe_event :: %{
          id: String.t(),
          type: String.t(),
          data: %{object: map()},
          created: pos_integer()
        }

  @type dispatch_result :: :ok | {:error, atom() | String.t()}

  @spec dispatch(stripe_event()) :: dispatch_result()
  def dispatch(%{type: type, data: %{object: object}, id: event_id} = _event) do
    handler = resolve_handler(type)

    case handler do
      nil ->
        :ok

      module ->
        case apply(module, :handle, [object, event_id]) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec dispatch_raw(String.t(), map()) :: dispatch_result()
  def dispatch_raw(raw_json, headers) when is_binary(raw_json) do
    with {:ok, decoded} <- Jason.decode(raw_json, keys: :atoms),
         :ok <- verify_event_shape(decoded) do
      dispatch(decoded)
    end
  end

  @spec resolve_handler(String.t()) :: module() | nil
  defp resolve_handler("payment_intent.succeeded"), do: PaymentIntentHandler
  defp resolve_handler("payment_intent.payment_failed"), do: PaymentIntentHandler
  defp resolve_handler("payment_intent.canceled"), do: PaymentIntentHandler
  defp resolve_handler("customer.subscription.created"), do: SubscriptionHandler
  defp resolve_handler("customer.subscription.updated"), do: SubscriptionHandler
  defp resolve_handler("customer.subscription.deleted"), do: SubscriptionHandler
  defp resolve_handler("customer.subscription.trial_will_end"), do: SubscriptionHandler
  defp resolve_handler("invoice.paid"), do: InvoiceHandler
  defp resolve_handler("invoice.payment_failed"), do: InvoiceHandler
  defp resolve_handler("invoice.upcoming"), do: InvoiceHandler
  defp resolve_handler("customer.created"), do: CustomerHandler
  defp resolve_handler("customer.updated"), do: CustomerHandler
  defp resolve_handler("customer.deleted"), do: CustomerHandler
  defp resolve_handler(_unknown), do: nil

  @spec verify_event_shape(map()) :: :ok | {:error, :invalid_event}
  defp verify_event_shape(%{id: id, type: type, data: %{object: _}})
       when is_binary(id) and is_binary(type) do
    :ok
  end

  defp verify_event_shape(_), do: {:error, :invalid_event}
end
```
