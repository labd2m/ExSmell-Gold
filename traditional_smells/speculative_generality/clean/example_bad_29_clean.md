```elixir
defmodule Auth.PermissionChecker do
  @moduledoc """
  Evaluates whether an authenticated actor has permission to perform
  a requested action on a given resource.

  Permission checks combine role-based scope resolution with
  resource-level policy evaluation.
  """

  alias Auth.{Actor, Policy, ResourceContext}

  require Logger

  @spec permitted?(Actor.t(), atom(), ResourceContext.t()) :: boolean()
  def permitted?(%Actor{} = actor, action, %ResourceContext{} = ctx) do
    scope = resolve_scope(actor)

    case Policy.evaluate(actor, action, ctx, scope) do
      {:ok, :allowed} ->
        true

      {:ok, :denied} ->
        Logger.info("Permission denied actor=#{actor.id} action=#{action} resource=#{ctx.resource_type}")
        false

      {:error, reason} ->
        Logger.error("Permission check error actor=#{actor.id}: #{inspect(reason)}")
        false
    end
  end

  @spec assert!(Actor.t(), atom(), ResourceContext.t()) :: :ok | no_return()
  def assert!(%Actor{} = actor, action, %ResourceContext{} = ctx) do
    if permitted?(actor, action, ctx) do
      :ok
    else
      raise Auth.PermissionDeniedError,
        message: "Actor #{actor.id} is not permitted to #{action} on #{ctx.resource_type}"
    end
  end

  @spec list_permitted_actions(Actor.t(), ResourceContext.t()) :: [atom()]
  def list_permitted_actions(%Actor{} = actor, %ResourceContext{} = ctx) do
    scope = resolve_scope(actor)

    Policy.available_actions(ctx)
    |> Enum.filter(fn action ->
      case Policy.evaluate(actor, action, ctx, scope) do
        {:ok, :allowed} -> true
        _ -> false
      end
    end)
  end

  defp resolve_scope(%{role: role}) do
    case role do
      _ -> :default
    end
  end

  defp resolve_scope(_actor), do: :default
end

defmodule Auth.Policy do
  @moduledoc false

  alias Auth.{Actor, ResourceContext}

  @spec evaluate(Actor.t(), atom(), ResourceContext.t(), atom()) ::
          {:ok, :allowed | :denied} | {:error, atom()}
  def evaluate(%Actor{} = actor, action, %ResourceContext{} = ctx, _scope) do
    cond do
      actor.superadmin? -> {:ok, :allowed}
      action in actor.granted_actions and ctx.owner_id == actor.id -> {:ok, :allowed}
      action in actor.granted_actions and ctx.visibility == :public -> {:ok, :allowed}
      true -> {:ok, :denied}
    end
  end

  @spec available_actions(ResourceContext.t()) :: [atom()]
  def available_actions(%ResourceContext{resource_type: :document}),
    do: [:read, :write, :delete, :share]

  def available_actions(%ResourceContext{resource_type: :report}),
    do: [:read, :export, :share]

  def available_actions(_ctx), do: [:read]
end
```
