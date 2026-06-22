```elixir
defmodule Saascore.Subscriptions do
  @moduledoc """
  Public context for managing customer subscription records.
  Provides lifecycle operations: creation, plan changes, and cancellation.
  All mutations are wrapped in database transactions for consistency.
  """

  import Ecto.Query, warn: false

  alias Saascore.Repo
  alias Saascore.Subscriptions.{Plan, Subscription}

  @type subscription_params :: %{
          required(:customer_id) => Ecto.UUID.t(),
          required(:plan_id) => Ecto.UUID.t(),
          optional(:trial_ends_at) => DateTime.t()
        }

  @spec list_active(Ecto.UUID.t()) :: [Subscription.t()]
  def list_active(customer_id) when is_binary(customer_id) do
    Subscription
    |> where([s], s.customer_id == ^customer_id and s.status == :active)
    |> order_by([s], desc: s.inserted_at)
    |> preload(:plan)
    |> Repo.all()
  end

  @spec get_subscription(Ecto.UUID.t()) :: {:ok, Subscription.t()} | {:error, :not_found}
  def get_subscription(id) when is_binary(id) do
    case Repo.get(Subscription, id) do
      nil -> {:error, :not_found}
      subscription -> {:ok, subscription}
    end
  end

  @spec create_subscription(subscription_params()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def create_subscription(params) when is_map(params) do
    Repo.transaction(fn ->
      with {:ok, plan} <- fetch_plan(params.plan_id),
           changeset <- Subscription.creation_changeset(%Subscription{}, params, plan),
           {:ok, subscription} <- Repo.insert(changeset) do
        subscription
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec change_plan(Subscription.t(), Ecto.UUID.t()) ::
          {:ok, Subscription.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def change_plan(%Subscription{} = subscription, new_plan_id) when is_binary(new_plan_id) do
    Repo.transaction(fn ->
      with {:ok, plan} <- fetch_plan(new_plan_id),
           changeset <- Subscription.plan_change_changeset(subscription, plan),
           {:ok, updated} <- Repo.update(changeset) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec cancel_subscription(Subscription.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def cancel_subscription(%Subscription{} = subscription) do
    subscription
    |> Subscription.cancellation_changeset()
    |> Repo.update()
  end

  @spec fetch_plan(Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, :not_found}
  defp fetch_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end
end

defmodule Saascore.Subscriptions.Subscription do
  @moduledoc """
  Ecto schema and changeset logic for a customer subscription.
  Encapsulates all field validation and state transition rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Saascore.Subscriptions.Plan

  @type status :: :trialing | :active | :past_due | :canceled
  @type t :: %__MODULE__{}

  schema "subscriptions" do
    field :status, Ecto.Enum, values: [:trialing, :active, :past_due, :canceled]
    field :trial_ends_at, :utc_datetime
    field :canceled_at, :utc_datetime

    belongs_to :customer, Saascore.Accounts.Customer, type: :binary_id
    belongs_to :plan, Plan, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(t(), map(), Plan.t()) :: Ecto.Changeset.t()
  def creation_changeset(%__MODULE__{} = subscription, params, %Plan{} = plan) do
    initial_status = if params[:trial_ends_at], do: :trialing, else: :active

    subscription
    |> cast(params, [:customer_id, :trial_ends_at])
    |> validate_required([:customer_id])
    |> put_assoc(:plan, plan)
    |> put_change(:status, initial_status)
    |> foreign_key_constraint(:customer_id)
  end

  @spec plan_change_changeset(t(), Plan.t()) :: Ecto.Changeset.t()
  def plan_change_changeset(%__MODULE__{} = subscription, %Plan{} = plan) do
    subscription
    |> change()
    |> put_assoc(:plan, plan)
    |> validate_inclusion(:status, [:trialing, :active])
  end

  @spec cancellation_changeset(t()) :: Ecto.Changeset.t()
  def cancellation_changeset(%__MODULE__{} = subscription) do
    subscription
    |> change(status: :canceled, canceled_at: DateTime.utc_now())
    |> validate_inclusion(:status, [:trialing, :active, :past_due])
  end
end
```
