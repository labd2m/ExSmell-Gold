```elixir
defmodule Access.Policy do
  @moduledoc """
  Evaluates role-based access control rules for a given subject and resource.
  Rules are defined as a list of permission structs loaded at startup.
  Evaluation is purely functional; no process state is required.
  """

  @type role :: atom()
  @type action :: atom()
  @type resource_type :: atom()

  @type permission :: %{
          role: role(),
          resource_type: resource_type(),
          actions: [action()]
        }

  @type subject :: %{required(:roles) => [role()]}

  @doc """
  Returns `:ok` when any of the subject's roles grant the requested action
  on the given resource type. Returns `{:error, :forbidden}` otherwise.
  """
  @spec authorize(subject(), resource_type(), action(), [permission()]) ::
          :ok | {:error, :forbidden}
  def authorize(%{roles: roles}, resource_type, action, permissions)
      when is_atom(resource_type) and is_atom(action) and is_list(roles) and is_list(permissions) do
    granted =
      Enum.any?(permissions, fn perm ->
        perm.resource_type == resource_type and
          perm.role in roles and
          action in perm.actions
      end)

    if granted, do: :ok, else: {:error, :forbidden}
  end

  @doc """
  Returns all actions a subject may perform on a resource type,
  as a deduplicated list of action atoms.
  """
  @spec permitted_actions(subject(), resource_type(), [permission()]) :: [action()]
  def permitted_actions(%{roles: roles}, resource_type, permissions)
      when is_atom(resource_type) and is_list(roles) do
    permissions
    |> Enum.filter(&(&1.resource_type == resource_type and &1.role in roles))
    |> Enum.flat_map(& &1.actions)
    |> Enum.uniq()
  end
end

defmodule Access.PolicyLoader do
  @moduledoc """
  Loads a permission set from a keyword-list configuration block.
  Validates that each entry has the expected shape before returning.
  """

  alias Access.Policy

  @doc "Parses a list of permission keyword lists into typed permission structs."
  @spec load([keyword()]) :: {:ok, [Policy.permission()]} | {:error, {:malformed_rule, term()}}
  def load(rules) when is_list(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
      case parse_rule(rule) do
        {:ok, perm} -> {:cont, {:ok, [perm | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, perms} -> {:ok, Enum.reverse(perms)}
      error -> error
    end
  end

  defp parse_rule(rule) when is_list(rule) do
    with {:ok, role} <- fetch_atom(rule, :role),
         {:ok, resource_type} <- fetch_atom(rule, :resource_type),
         {:ok, actions} <- fetch_atom_list(rule, :actions) do
      {:ok, %{role: role, resource_type: resource_type, actions: actions}}
    end
  end

  defp parse_rule(bad), do: {:error, {:malformed_rule, bad}}

  defp fetch_atom(kw, key) do
    case Keyword.fetch(kw, key) do
      {:ok, v} when is_atom(v) -> {:ok, v}
      _ -> {:error, {:malformed_rule, {key, :not_an_atom}}}
    end
  end

  defp fetch_atom_list(kw, key) do
    case Keyword.fetch(kw, key) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_atom/1),
          do: {:ok, list},
          else: {:error, {:malformed_rule, {key, :non_atom_in_list}}}
      _ ->
        {:error, {:malformed_rule, {key, :not_a_list}}}
    end
  end
end
```
