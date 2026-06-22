```elixir
defmodule Webhooks.EndpointRegistry do
  @moduledoc """
  Manages the lifecycle of registered webhook endpoint configurations.
  Endpoints specify a URL, secret, event subscriptions, and delivery
  settings. Provides lookup by event type for efficient fanout routing.
  """

  alias Webhooks.{Repo, Endpoint}
  import Ecto.Query

  @type endpoint_id :: String.t()
  @type owner_id :: String.t()
  @type event_type :: String.t()

  @spec register(owner_id(), map()) :: {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def register(owner_id, params) when is_binary(owner_id) do
    secret = generate_secret()

    %Endpoint{}
    |> Endpoint.creation_changeset(Map.merge(params, %{owner_id: owner_id, secret: secret}))
    |> Repo.insert()
  end

  @spec update(endpoint_id(), owner_id(), map()) ::
          {:ok, Endpoint.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(endpoint_id, owner_id, params) do
    with {:ok, endpoint} <- fetch_owned(endpoint_id, owner_id) do
      endpoint |> Endpoint.update_changeset(params) |> Repo.update()
    end
  end

  @spec rotate_secret(endpoint_id(), owner_id()) ::
          {:ok, %{endpoint: Endpoint.t(), new_secret: String.t()}} | {:error, :not_found}
  def rotate_secret(endpoint_id, owner_id) do
    with {:ok, endpoint} <- fetch_owned(endpoint_id, owner_id) do
      new_secret = generate_secret()

      case endpoint |> Endpoint.update_changeset(%{secret: new_secret}) |> Repo.update() do
        {:ok, updated} -> {:ok, %{endpoint: updated, new_secret: new_secret}}
        {:error, _} = err -> err
      end
    end
  end

  @spec deactivate(endpoint_id(), owner_id()) :: :ok | {:error, :not_found}
  def deactivate(endpoint_id, owner_id) do
    with {:ok, endpoint} <- fetch_owned(endpoint_id, owner_id) do
      endpoint |> Endpoint.update_changeset(%{active: false}) |> Repo.update()
      :ok
    end
  end

  @spec list_for_owner(owner_id()) :: [Endpoint.t()]
  def list_for_owner(owner_id) when is_binary(owner_id) do
    from(e in Endpoint,
      where: e.owner_id == ^owner_id,
      order_by: [desc: e.inserted_at]
    )
    |> Repo.all()
  end

  @spec endpoints_for_event(owner_id(), event_type()) :: [Endpoint.t()]
  def endpoints_for_event(owner_id, event_type) when is_binary(owner_id) do
    from(e in Endpoint,
      where:
        e.owner_id == ^owner_id and
          e.active == true and
          (^event_type in e.subscribed_events or "*" in e.subscribed_events),
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  @spec fetch!(endpoint_id()) :: Endpoint.t()
  def fetch!(endpoint_id) when is_binary(endpoint_id) do
    Repo.get!(Endpoint, endpoint_id)
  end

  @spec fetch_owned(endpoint_id(), owner_id()) :: {:ok, Endpoint.t()} | {:error, :not_found}
  defp fetch_owned(endpoint_id, owner_id) do
    case Repo.get_by(Endpoint, id: endpoint_id, owner_id: owner_id) do
      nil -> {:error, :not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  @spec generate_secret() :: String.t()
  defp generate_secret do
    "whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end
end
```
