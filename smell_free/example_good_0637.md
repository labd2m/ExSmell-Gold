```elixir
defmodule Comms.WebhookRegistry do
  @moduledoc """
  Manages customer webhook endpoint registrations. Each endpoint
  subscribes to a set of event types and carries a secret used to sign
  outbound payloads. Registration enforces URL validity and a per-customer
  endpoint limit to prevent abuse. The registry provides a fast lookup
  returning all endpoints that should receive a given event type.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Comms.WebhookEndpoint

  @type customer_id :: String.t()
  @type endpoint_id :: Ecto.UUID.t()
  @type event_type :: String.t()

  @max_endpoints_per_customer 10
  @valid_url_pattern ~r|^https?://[^\s/$.?#][^\s]*$|i

  @doc """
  Registers a webhook endpoint for `customer_id`. Returns
  `{:error, :limit_reached}` when the customer already has the maximum
  number of active endpoints.
  """
  @spec register(customer_id(), String.t(), [event_type()]) ::
          {:ok, %{endpoint: WebhookEndpoint.t(), signing_secret: String.t()}}
          | {:error, :invalid_url | :limit_reached | Ecto.Changeset.t()}
  def register(customer_id, url, event_types)
      when is_binary(customer_id) and is_binary(url) and is_list(event_types) do
    with :ok <- validate_url(url),
         :ok <- check_limit(customer_id) do
      secret = generate_secret()

      attrs = %{
        customer_id: customer_id,
        url: url,
        event_types: event_types,
        signing_secret_hash: hash_secret(secret),
        active: true
      }

      case %WebhookEndpoint{} |> WebhookEndpoint.changeset(attrs) |> Repo.insert() do
        {:ok, endpoint} -> {:ok, %{endpoint: endpoint, signing_secret: secret}}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  @doc "Deactivates a webhook endpoint without deleting its record."
  @spec deactivate(endpoint_id(), customer_id()) ::
          :ok | {:error, :not_found | :not_owner}
  def deactivate(endpoint_id, customer_id)
      when is_binary(endpoint_id) and is_binary(customer_id) do
    case Repo.get(WebhookEndpoint, endpoint_id) do
      nil -> {:error, :not_found}
      %WebhookEndpoint{customer_id: ^customer_id} = ep ->
        ep |> WebhookEndpoint.changeset(%{active: false}) |> Repo.update()
        :ok

      %WebhookEndpoint{} -> {:error, :not_owner}
    end
  end

  @doc """
  Returns all active endpoints subscribed to `event_type`, across all
  customers. Used by the delivery pipeline to fanout events.
  """
  @spec endpoints_for_event(event_type()) :: [WebhookEndpoint.t()]
  def endpoints_for_event(event_type) when is_binary(event_type) do
    from(e in WebhookEndpoint,
      where: e.active == true and ^event_type in e.event_types
    )
    |> Repo.all()
  end

  @doc "Returns all active endpoints registered by `customer_id`."
  @spec list_for_customer(customer_id()) :: [WebhookEndpoint.t()]
  def list_for_customer(customer_id) when is_binary(customer_id) do
    from(e in WebhookEndpoint,
      where: e.customer_id == ^customer_id and e.active == true,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  defp validate_url(url) do
    if String.match?(url, @valid_url_pattern), do: :ok, else: {:error, :invalid_url}
  end

  defp check_limit(customer_id) do
    count =
      from(e in WebhookEndpoint,
        where: e.customer_id == ^customer_id and e.active == true,
        select: count(e.id)
      )
      |> Repo.one()

    if count < @max_endpoints_per_customer, do: :ok, else: {:error, :limit_reached}
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end
end
```
