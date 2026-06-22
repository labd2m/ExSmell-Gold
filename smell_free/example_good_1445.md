```elixir
defmodule MyApp.Platform.WebhookRegistry do
  @moduledoc """
  Manages a tenant's registered webhook endpoints. Subscribers register
  URLs against one or more event types; the dispatcher consults this
  registry to find active endpoints for each outbound event. Endpoints
  can be paused individually without being deleted, supporting temporary
  disablement while a subscriber's infrastructure is down.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Platform.WebhookEndpoint

  @type tenant_id :: String.t()
  @type event_type :: String.t()
  @type endpoint_id :: String.t()

  @doc """
  Registers a new webhook endpoint for `tenant_id`. The endpoint starts
  in an active state. Returns `{:error, :url_already_registered}` when
  the same URL already exists for the tenant.
  """
  @spec register(tenant_id(), map()) ::
          {:ok, WebhookEndpoint.t()}
          | {:error, :url_already_registered}
          | {:error, Ecto.Changeset.t()}
  def register(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    if url_taken?(tenant_id, url) do
      {:error, :url_already_registered}
    else
      secret = generate_secret()

      %WebhookEndpoint{}
      |> WebhookEndpoint.changeset(Map.merge(attrs, %{tenant_id: tenant_id, secret: secret, active: true}))
      |> Repo.insert()
    end
  end

  @doc "Returns all active endpoints for `tenant_id` subscribed to `event_type`."
  @spec endpoints_for(tenant_id(), event_type()) :: [WebhookEndpoint.t()]
  def endpoints_for(tenant_id, event_type) when is_binary(tenant_id) and is_binary(event_type) do
    WebhookEndpoint
    |> where([e], e.tenant_id == ^tenant_id and e.active == true)
    |> where([e], ^event_type in e.event_types or "\"*\"" in e.event_types)
    |> Repo.all()
  end

  @doc "Pauses `endpoint_id` for `tenant_id`, stopping deliveries without deletion."
  @spec pause(tenant_id(), endpoint_id()) :: :ok | {:error, :not_found}
  def pause(tenant_id, endpoint_id) when is_binary(tenant_id) do
    toggle_active(tenant_id, endpoint_id, false)
  end

  @doc "Resumes a paused endpoint."
  @spec resume(tenant_id(), endpoint_id()) :: :ok | {:error, :not_found}
  def resume(tenant_id, endpoint_id) when is_binary(tenant_id) do
    toggle_active(tenant_id, endpoint_id, true)
  end

  @doc "Rotates the signing secret for `endpoint_id` and returns the new secret."
  @spec rotate_secret(tenant_id(), endpoint_id()) ::
          {:ok, String.t()} | {:error, :not_found}
  def rotate_secret(tenant_id, endpoint_id) when is_binary(tenant_id) do
    case Repo.get_by(WebhookEndpoint, id: endpoint_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        new_secret = generate_secret()
        endpoint |> WebhookEndpoint.changeset(%{secret: new_secret}) |> Repo.update()
        {:ok, new_secret}
    end
  end

  @doc "Deletes `endpoint_id` and all its delivery history for `tenant_id`."
  @spec delete(tenant_id(), endpoint_id()) :: :ok | {:error, :not_found}
  def delete(tenant_id, endpoint_id) when is_binary(tenant_id) do
    case Repo.get_by(WebhookEndpoint, id: endpoint_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      endpoint -> Repo.delete(endpoint) && :ok
    end
  end

  @spec toggle_active(tenant_id(), endpoint_id(), boolean()) :: :ok | {:error, :not_found}
  defp toggle_active(tenant_id, endpoint_id, active) do
    case Repo.get_by(WebhookEndpoint, id: endpoint_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      ep -> ep |> WebhookEndpoint.changeset(%{active: active}) |> Repo.update() && :ok
    end
  end

  @spec url_taken?(tenant_id(), String.t() | nil) :: boolean()
  defp url_taken?(_tenant_id, nil), do: false

  defp url_taken?(tenant_id, url) do
    WebhookEndpoint
    |> where([e], e.tenant_id == ^tenant_id and e.url == ^url)
    |> Repo.exists?()
  end

  @spec generate_secret() :: String.t()
  defp generate_secret do
    32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
```
