```elixir
defmodule Payments.WebhookEventTypeParser do
  @moduledoc """
  Parses payment gateway webhook event type strings into structured routing data.

  The webhook dispatcher uses parsed event types to route incoming webhook
  payloads to the correct domain handler. This module is responsible for
  decomposing the raw event type string from the gateway into the resource
  and action dimensions used for handler lookup.

  Stripe event type format:
    "<resource>.<action>"

  Examples:
    "payment_intent.succeeded"
    "payment_intent.payment_failed"
    "invoice.paid"
    "invoice.payment_failed"
    "customer.subscription.deleted"
    "charge.refunded"
    "checkout.session.completed"
  """

  require Logger

  @known_resources ~w(
    payment_intent
    invoice
    customer
    charge
    checkout
    subscription
    refund
    dispute
    payout
  )

  @doc """
  Parses a raw webhook event type string into a structured map.

  Returns `{:ok, %{resource: resource, action: action, raw: raw}}` on success,
  or `{:error, reason}` when the resource is not in the known set.
  """

  def parse(raw) when is_binary(raw) do
    parts    = String.split(raw, ".")
    resource = Enum.at(parts, 0)
    action   = Enum.at(parts, 1)

    with :ok <- validate_resource(resource) do
      {:ok, %{
        resource: resource,
        action:   action,
        raw:      raw
      }}
    end
  end

  @doc """
  Returns the handler module atom for a parsed event, based on the resource type.
  Returns `{:error, :no_handler}` when no handler is registered for the resource.
  """
  def resolve_handler(%{resource: resource}) do
    handler_registry()[resource] || {:error, :no_handler}
  end

  @doc """
  Returns true when the parsed event represents a successful payment outcome.
  """
  def success_event?(%{action: "succeeded"}),        do: true
  def success_event?(%{action: "paid"}),             do: true
  def success_event?(%{action: "payment_succeeded"}),do: true
  def success_event?(_),                             do: false

  @doc """
  Returns true when the parsed event represents a failure or reversal.
  """
  def failure_event?(%{action: action}) when is_binary(action) do
    String.contains?(action, "fail") or
    String.contains?(action, "declined") or
    action in ~w(refunded disputed voided)
  end

  def failure_event?(_), do: false

  @doc """
  Returns a human-readable description of the event for audit logging.
  """
  def describe(%{resource: r, action: a}) do
    "#{String.replace(r, "_", " ")} #{String.replace(a || "unknown", "_", " ")}"
  end

  @doc """
  Parses a list of event type strings, returning partitioned ok/error results.
  """
  def parse_many(raw_events) when is_list(raw_events) do
    raw_events
    |> Enum.map(&{&1, parse(&1)})
    |> Enum.group_by(fn {_, result} -> elem(result, 0) end)
    |> then(fn groups ->
      ok     = for {_, {:ok, info}}       <- Map.get(groups, :ok, []),    do: info
      errors = for {raw, {:error, reason}} <- Map.get(groups, :error, []), do: %{raw: raw, reason: reason}
      %{ok: ok, error: errors}
    end)
  end

  @doc """
  Returns all known resource names supported by the dispatcher.
  """
  def known_resources, do: @known_resources

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_resource(resource) when is_binary(resource) do
    if resource in @known_resources do
      :ok
    else
      {:error, {:unknown_resource, resource}}
    end
  end

  defp validate_resource(nil), do: {:error, :missing_resource}
  defp validate_resource(_),   do: {:error, :invalid_resource}

  defp handler_registry do
    %{
      "payment_intent" => Payments.Handlers.PaymentIntentHandler,
      "invoice"        => Payments.Handlers.InvoiceHandler,
      "customer"       => Payments.Handlers.CustomerHandler,
      "charge"         => Payments.Handlers.ChargeHandler,
      "checkout"       => Payments.Handlers.CheckoutHandler,
      "subscription"   => Payments.Handlers.SubscriptionHandler,
      "refund"         => Payments.Handlers.RefundHandler,
      "dispute"        => Payments.Handlers.DisputeHandler,
      "payout"         => Payments.Handlers.PayoutHandler
    }
  end
end
```
