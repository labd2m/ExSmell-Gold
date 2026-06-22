```elixir
defmodule Access.Policy.RuleEngine do
  @moduledoc """
  Evaluates role-based access control rules for resource operations.
  Rules are composable and evaluated in priority order until a decision is reached.
  """

  @type principal :: %{id: String.t(), roles: [atom()]}
  @type resource :: %{type: atom(), owner_id: String.t()}
  @type operation :: :read | :write | :delete | :admin
  @type decision :: :allow | :deny
  @type rule :: (principal(), resource(), operation() -> decision() | :abstain)

  @doc """
  Evaluates `rules` against the given principal, resource, and operation.

  Rules are evaluated in order. The first rule returning `:allow` or `:deny` wins.
  If all rules abstain, `:deny` is returned by default.
  """
  @spec evaluate([rule()], principal(), resource(), operation()) :: decision()
  def evaluate(rules, principal, resource, operation)
      when is_list(rules) and is_map(principal) and is_map(resource) and
             operation in [:read, :write, :delete, :admin] do
    Enum.reduce_while(rules, :deny, fn rule, _acc ->
      case rule.(principal, resource, operation) do
        :allow -> {:halt, :allow}
        :deny -> {:halt, :deny}
        :abstain -> {:cont, :deny}
      end
    end)
  end

  @doc """
  A rule that allows any operation for principals with the `:admin` role.
  """
  @spec admin_rule(principal(), resource(), operation()) :: decision() | :abstain
  def admin_rule(%{roles: roles}, _resource, _operation) do
    if :admin in roles, do: :allow, else: :abstain
  end

  @doc """
  A rule that allows `:read` operations for any authenticated principal.
  """
  @spec authenticated_read_rule(principal(), resource(), operation()) :: decision() | :abstain
  def authenticated_read_rule(%{id: id}, _resource, :read) when is_binary(id) and id != "" do
    :allow
  end

  def authenticated_read_rule(_principal, _resource, _operation), do: :abstain

  @doc """
  A rule that allows all operations on resources owned by the principal.
  """
  @spec owner_rule(principal(), resource(), operation()) :: decision() | :abstain
  def owner_rule(%{id: user_id}, %{owner_id: owner_id}, _operation)
      when user_id == owner_id and is_binary(user_id) and user_id != "" do
    :allow
  end

  def owner_rule(_principal, _resource, _operation), do: :abstain

  @doc """
  A rule that denies `:delete` operations for principals without the `:moderator` role.
  """
  @spec delete_moderator_rule(principal(), resource(), operation()) :: decision() | :abstain
  def delete_moderator_rule(%{roles: roles}, _resource, :delete) do
    if :moderator in roles, do: :abstain, else: :deny
  end

  def delete_moderator_rule(_principal, _resource, _operation), do: :abstain

  @doc """
  Builds a default rule list suitable for standard content platforms.
  """
  @spec default_rules() :: [rule()]
  def default_rules do
    [
      &admin_rule/3,
      &owner_rule/3,
      &delete_moderator_rule/3,
      &authenticated_read_rule/3
    ]
  end
end
```
