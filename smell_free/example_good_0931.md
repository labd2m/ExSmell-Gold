```elixir
defmodule Webhooks.Subscriptions do
  @moduledoc """
  Context for managing webhook endpoint subscriptions.

  Owners register HTTPS endpoints to receive event notifications.
  Each subscription scopes to a specific set of event types and
  optionally enforces a signing secret for delivery verification.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Webhooks.{Repo, Subscription, DeliveryAttempt}

  @type owner_id :: pos_integer()
  @type subscription_attrs :: %{
          required(:url) => String.t(),
          required(:event_types) => [String.t()],
          optional(:description) => String.t(),
          optional(:secret) => String.t()
        }

  @doc """
  Creates a new webhook subscription for `owner_id`.
  Generates a signing secret if none is provided.
  """
  @spec create(owner_id(), subscription_attrs()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def create(owner_id, attrs) when is_integer(owner_id) do
    secret = Map.get_lazy(attrs, :secret, &generate_secret/0)

    %Subscription{}
    |> Subscription.changeset(Map.merge(attrs, %{owner_id: owner_id, secret: secret, active: true}))
    |> Repo.insert()
  end

  @doc """
  Updates a subscription's URL, event types, or description.
  The signing secret cannot be changed; rotate it via `rotate_secret/1`.
  """
  @spec update(Subscription.t(), map()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def update(%Subscription{} = subscription, attrs) do
    subscription
    |> Subscription.update_changeset(Map.drop(attrs, [:secret, :owner_id]))
    |> Repo.update()
  end

  @doc "Rotates the signing secret and returns the new secret."
  @spec rotate_secret(Subscription.t()) ::
          {:ok, %{subscription: Subscription.t(), new_secret: String.t()}} | {:error, Ecto.Changeset.t()}
  def rotate_secret(%Subscription{} = subscription) do
    new_secret = generate_secret()

    case subscription |> Subscription.changeset(%{secret: new_secret}) |> Repo.update() do
      {:ok, updated} -> {:ok, %{subscription: updated, new_secret: new_secret}}
      error -> error
    end
  end

  @doc "Pauses deliveries to an endpoint without deleting the subscription."
  @spec pause(Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def pause(%Subscription{} = subscription) do
    subscription |> Subscription.changeset(%{active: false}) |> Repo.update()
  end

  @doc "Resumes deliveries to a paused endpoint."
  @spec resume(Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def resume(%Subscription{} = subscription) do
    subscription |> Subscription.changeset(%{active: true}) |> Repo.update()
  end

  @doc "Permanently deletes a subscription and its delivery history."
  @spec delete(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def delete(%Subscription{} = subscription) do
    Multi.new()
    |> Multi.delete_all(:deliveries, fn _ ->
      from(d in DeliveryAttempt, where: d.subscription_id == ^subscription.id)
    end)
    |> Multi.delete(:subscription, subscription)
    |> Repo.transaction()
    |> case do
      {:ok, %{subscription: deleted}} -> {:ok, deleted}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Lists all active subscriptions for `owner_id` matching any of `event_types`."
  @spec list_for_event(owner_id(), String.t()) :: [Subscription.t()]
  def list_for_event(owner_id, event_type) when is_binary(event_type) do
    from(s in Subscription,
      where: s.owner_id == ^owner_id and s.active == true and ^event_type in s.event_types,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Returns all subscriptions belonging to `owner_id`."
  @spec list(owner_id()) :: [Subscription.t()]
  def list(owner_id) when is_integer(owner_id) do
    from(s in Subscription,
      where: s.owner_id == ^owner_id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Fetches a subscription by id, scoped to `owner_id`."
  @spec fetch(pos_integer(), owner_id()) :: {:ok, Subscription.t()} | {:error, :not_found}
  def fetch(id, owner_id) when is_integer(id) do
    case Repo.get_by(Subscription, id: id, owner_id: owner_id) do
      nil -> {:error, :not_found}
      sub -> {:ok, sub}
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
```
