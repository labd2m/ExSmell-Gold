# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `PermissionChecker.assert_permitted!/3`
- **Affected function(s):** `PermissionChecker.assert_permitted!/3`, `ResourceController.update/3`
- **Short explanation:** `PermissionChecker.assert_permitted!/3` is the only public function for checking resource permissions, and it raises a `PermissionDeniedError` when access is not allowed. Authorisation denial is an entirely ordinary, expected outcome — not an exceptional one. Because no `check_permitted/3` variant returning `{:ok, :permitted} | {:error, :denied}` is provided, all callers must use `try/rescue` blocks to handle routine authorisation logic.

---

## Code

```elixir
defmodule PermissionChecker do
  @moduledoc """
  Evaluates whether a user is permitted to perform an action on a given resource,
  based on roles, ownership, and policy rules.
  """

  defmodule PermissionDeniedError do
    defexception [:message, :user_id, :action, :resource_type]

    @impl true
    def exception(opts) do
      user_id = Keyword.fetch!(opts, :user_id)
      action = Keyword.fetch!(opts, :action)
      resource_type = Keyword.fetch!(opts, :resource_type)

      %__MODULE__{
        message:
          "User #{user_id} is not permitted to perform #{action} on #{resource_type}",
        user_id: user_id,
        action: action,
        resource_type: resource_type
      }
    end
  end

  @role_permissions %{
    admin: [:read, :write, :delete, :manage_members],
    editor: [:read, :write],
    viewer: [:read],
    billing_manager: [:read, :write, :manage_billing]
  }

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because assert_permitted!/3 is the only entry point
  # VALIDATION: for permission checks and it raises PermissionDeniedError for access
  # VALIDATION: denial — a completely routine, expected authorisation outcome.
  # VALIDATION: Callers like ResourceController must wrap every check in try/rescue
  # VALIDATION: to branch on permitted vs denied, because no non-raising alternative
  # VALIDATION: (e.g., check_permitted/3 returning {:ok, :permitted} | {:error, :denied})
  # VALIDATION: is offered.
  def assert_permitted!(user, action, resource) do
    unless is_map(user) and Map.has_key?(user, :id) do
      raise ArgumentError, "user must be a map with an :id field"
    end

    unless is_atom(action) do
      raise ArgumentError, "action must be an atom, got: #{inspect(action)}"
    end

    role = Map.get(user, :role, :viewer)
    allowed_actions = Map.get(@role_permissions, role, [])

    cond do
      action in [:delete, :manage_members] and role != :admin ->
        raise PermissionDeniedError,
          user_id: user.id,
          action: action,
          resource_type: resource_type(resource)

      action == :manage_billing and role not in [:admin, :billing_manager] ->
        raise PermissionDeniedError,
          user_id: user.id,
          action: action,
          resource_type: resource_type(resource)

      action in allowed_actions ->
        :ok

      true ->
        raise PermissionDeniedError,
          user_id: user.id,
          action: action,
          resource_type: resource_type(resource)
    end
  end
  # VALIDATION: SMELL END

  def list_permissions(role) do
    Map.get(@role_permissions, role, [])
  end

  defp resource_type(%{__struct__: mod}), do: mod |> Module.split() |> List.last()
  defp resource_type(%{type: t}), do: to_string(t)
  defp resource_type(_), do: "Resource"
end

defmodule ResourceController do
  @moduledoc """
  Handles CRUD operations on workspace resources, enforcing authorisation
  rules before each mutation.
  """

  require Logger

  alias PermissionChecker
  alias PermissionChecker.PermissionDeniedError

  def show(current_user, resource_id) do
    resource = fetch_resource(resource_id)

    # Forced to use try/rescue because PermissionChecker only signals
    # denial via raised exceptions, not return values.
    try do
      PermissionChecker.assert_permitted!(current_user, :read, resource)
      Logger.info("User #{current_user.id} read resource #{resource_id}")
      {:ok, resource}
    rescue
      e in PermissionDeniedError ->
        Logger.info("Access denied: #{e.message}")
        {:error, :forbidden}
    end
  end

  def update(current_user, resource_id, attrs) do
    resource = fetch_resource(resource_id)

    try do
      PermissionChecker.assert_permitted!(current_user, :write, resource)

      updated = Map.merge(resource, attrs)
      Logger.info("User #{current_user.id} updated resource #{resource_id}")
      {:ok, updated}
    rescue
      e in PermissionDeniedError ->
        Logger.warning("Unauthorised update attempt by #{current_user.id}: #{e.message}")
        {:error, :forbidden}
    end
  end

  def delete(current_user, resource_id) do
    resource = fetch_resource(resource_id)

    try do
      PermissionChecker.assert_permitted!(current_user, :delete, resource)
      Logger.info("User #{current_user.id} deleted resource #{resource_id}")
      :ok
    rescue
      e in PermissionDeniedError ->
        Logger.warning("Unauthorised delete attempt by #{current_user.id}: #{e.message}")
        {:error, :forbidden}
    end
  end

  defp fetch_resource(id) do
    %{id: id, type: :document, owner_id: "user-999", content: "Sample content"}
  end
end
```
