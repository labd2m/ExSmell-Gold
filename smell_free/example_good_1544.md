```elixir
defmodule Access.PermissionEvaluator do
  @moduledoc """
  Policy-based permission evaluator for resource access control.

  Evaluates structured permission rules against subject-resource-action
  triples. Rules are loaded from the database and cached per process to
  minimize query overhead within request lifecycles.
  """

  alias Access.{Role, Permission, Repo}

  @type subject :: %{id: String.t(), role_ids: [String.t()]}
  @type resource :: String.t()
  @type action :: :read | :write | :delete | :admin

  @type evaluation_result :: :allow | :deny

  @process_cache_key :permission_rule_cache

  @doc """
  Evaluates whether a subject is permitted to perform an action on a resource.

  Returns `:allow` if at least one of the subject's roles grants the
  requested action on the target resource, otherwise returns `:deny`.
  """
  @spec evaluate(subject(), resource(), action()) :: evaluation_result()
  def evaluate(%{role_ids: role_ids}, resource, action)
      when is_binary(resource) and is_atom(action) do
    rules = load_rules(role_ids)
    check_permission(rules, resource, action)
  end

  @doc """
  Preloads and caches permission rules for a list of role IDs into the
  current process dictionary for fast repeated evaluations.
  """
  @spec preload_rules([String.t()]) :: :ok
  def preload_rules(role_ids) when is_list(role_ids) do
    rules = fetch_rules_from_db(role_ids)
    Process.put(@process_cache_key, {role_ids, rules})
    :ok
  end

  @doc """
  Clears any cached permission rules from the current process.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Process.delete(@process_cache_key)
    :ok
  end

  defp load_rules(role_ids) do
    case Process.get(@process_cache_key) do
      {^role_ids, cached_rules} ->
        cached_rules

      _ ->
        rules = fetch_rules_from_db(role_ids)
        Process.put(@process_cache_key, {role_ids, rules})
        rules
    end
  end

  defp fetch_rules_from_db(role_ids) do
    import Ecto.Query

    Repo.all(
      from(p in Permission,
        join: r in Role,
        on: r.id == p.role_id,
        where: r.id in ^role_ids and r.active == true,
        select: %{resource: p.resource, action: p.action}
      )
    )
  end

  defp check_permission(rules, resource, action) do
    match_found =
      Enum.any?(rules, fn rule ->
        matches_resource?(rule.resource, resource) and matches_action?(rule.action, action)
      end)

    if match_found, do: :allow, else: :deny
  end

  defp matches_resource?("*", _resource), do: true
  defp matches_resource?(rule_resource, resource), do: rule_resource == resource

  defp matches_action?(:admin, _action), do: true
  defp matches_action?(rule_action, action), do: rule_action == action
end
```
