```elixir
defmodule AccessControl.PolicyEncoder do
  @moduledoc """
  Encodes and decodes access control policy entries for the authorization layer.
  Policies are stored as structured strings in the format:
  `{action}:{resource_scope}:{effect}`, e.g. `read:documents/contracts:allow`.

  Used by the permission middleware, the admin policy editor, and the
  role-assignment service.
  """

  @separator ":"
  @scope_separator "/"
  @valid_actions ~w(read write delete admin)
  @valid_effects ~w(allow deny)
  @wildcard "*"

  @doc """
  Encodes a full policy entry from its components.

  ## Parameters
    - `action`: One of `"read"`, `"write"`, `"delete"`, `"admin"`.
    - `scope`: A resource scope value (binary or atom).
    - `effect`: Either `"allow"` or `"deny"`.
  """
  def encode_policy(action, scope, effect)
      when is_binary(action) and is_binary(effect) do
    with :ok <- validate_action(action),
         :ok <- validate_effect(effect) do
      encoded_scope = encode_resource_scope(scope)
      {:ok, Enum.join([action, encoded_scope, effect], @separator)}
    end
  end

  @doc """
  Encodes a resource scope value into its canonical string form.
  Nested scopes use `/` as a separator, e.g. `"documents/contracts"`.
  """
  def encode_resource_scope(scope) do
    "resource:" <> to_string(scope)
  end

  @doc """
  Decodes a policy string back into its components.
  Returns `{:ok, %{action, scope, effect}}` or `{:error, :invalid_policy}`.
  """
  def decode_policy(policy_string) when is_binary(policy_string) do
    case String.split(policy_string, @separator, parts: 3) do
      [action, scope, effect] ->
        with :ok <- validate_action(action),
             :ok <- validate_effect(effect) do
          {:ok, %{action: action, scope: scope, effect: effect}}
        end

      _ ->
        {:error, :invalid_policy}
    end
  end

  @doc """
  Builds a wildcard policy that applies to all resources for a given action.
  """
  def wildcard_policy(action, effect)
      when is_binary(action) and is_binary(effect) do
    encode_policy(action, @wildcard, effect)
  end

  @doc """
  Returns whether a policy entry grants access for a given action and resource path.
  """
  def grants_access?(policy_string, action, resource_path)
      when is_binary(policy_string) and is_binary(action) and is_binary(resource_path) do
    case decode_policy(policy_string) do
      {:ok, %{action: ^action, scope: scope, effect: "allow"}} ->
        scope_matches?(scope, resource_path)

      _ ->
        false
    end
  end

  @doc """
  Merges a list of policy strings, removing duplicates.
  """
  def merge_policies(policies_a, policies_b)
      when is_list(policies_a) and is_list(policies_b) do
    (policies_a ++ policies_b)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns the most permissive effect from a list of matching policy entries.
  `:allow` takes precedence over `:deny`.
  """
  def resolve_effect(matching_effects) when is_list(matching_effects) do
    if :allow in matching_effects, do: :allow, else: :deny
  end

  # --- Private ---

  defp validate_action(action) when action in @valid_actions, do: :ok
  defp validate_action(_), do: {:error, :invalid_action}

  defp validate_effect(effect) when effect in @valid_effects, do: :ok
  defp validate_effect(_), do: {:error, :invalid_effect}

  defp scope_matches?(@wildcard, _path), do: true

  defp scope_matches?(scope, path) when is_binary(scope) and is_binary(path) do
    scope_parts = String.split(scope, @scope_separator)
    path_parts = String.split(path, @scope_separator)

    Enum.zip(scope_parts, path_parts)
    |> Enum.all?(fn {s, p} -> s == @wildcard or s == p end)
  end
end
```
