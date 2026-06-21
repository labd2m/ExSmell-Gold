```elixir
defmodule Platform.AccessPolicy do
  @moduledoc """
  A pure-function access policy evaluator combining role-based and
  attribute-based access control for resource-level authorization.

  Policies are plain data structures loaded at startup. Evaluation is
  stateless and side-effect free, making it trivially testable and
  cacheable at the call site.
  """

  @type role :: atom()
  @type action :: atom()
  @type resource_type :: atom()
  @type subject :: %{id: pos_integer(), roles: [role()], attributes: map()}
  @type resource :: %{type: resource_type(), owner_id: pos_integer() | nil, attributes: map()}
  @type policy_decision :: :allow | :deny

  @doc """
  Evaluates whether `subject` may perform `action` on `resource`.

  Returns `:allow` if any policy rule grants access, `:deny` otherwise.
  Policy evaluation is short-circuiting: the first matching `:allow` wins.
  """
  @spec evaluate(subject(), action(), resource()) :: policy_decision()
  def evaluate(%{roles: roles} = subject, action, resource) do
    rules = rules_for(resource.type, action)

    result = Enum.reduce_while(rules, :deny, fn rule, _acc ->
      if rule_applies?(rule, subject, resource) do
        {:halt, rule.decision}
      else
        {:cont, :deny}
      end
    end)

    if result == :deny && owns_resource?(subject, resource) do
      :allow
    else
      result
    end
  end

  @doc "Returns `true` if `subject` is allowed to perform `action` on `resource`."
  @spec allows?(subject(), action(), resource()) :: boolean()
  def allows?(subject, action, resource), do: evaluate(subject, action, resource) == :allow

  defp rules_for(resource_type, action) do
    [
      %{resource: :document, action: :read, roles: [:viewer, :editor, :admin], decision: :allow},
      %{resource: :document, action: :edit, roles: [:editor, :admin], decision: :allow},
      %{resource: :document, action: :delete, roles: [:admin], decision: :allow},
      %{resource: :billing, action: :read, roles: [:billing_manager, :admin], decision: :allow},
      %{resource: :billing, action: :write, roles: [:billing_manager, :admin], decision: :allow},
      %{resource: :user, action: :read, roles: [:admin, :support], decision: :allow},
      %{resource: :user, action: :delete, roles: [:admin], decision: :allow}
    ]
    |> Enum.filter(&(&1.resource == resource_type && &1.action == action))
  end

  defp rule_applies?(%{roles: required_roles, decision: _}, %{roles: subject_roles}, _resource) do
    Enum.any?(required_roles, &(&1 in subject_roles))
  end

  defp owns_resource?(%{id: subject_id}, %{owner_id: owner_id}) when is_integer(owner_id) do
    subject_id == owner_id
  end

  defp owns_resource?(_subject, _resource), do: false
end

defmodule Platform.AccessPolicy.Plug do
  @moduledoc """
  A Plug that enforces access policy for a resource and action inferred from
  `conn.assigns`. Halts with 403 if the policy denies access.
  """

  import Plug.Conn
  alias Platform.AccessPolicy

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    action = Keyword.fetch!(opts, :action)
    resource_fn = Keyword.fetch!(opts, :resource)

    subject = build_subject(conn.assigns[:current_account])
    resource = resource_fn.(conn)

    case AccessPolicy.evaluate(subject, action, resource) do
      :allow -> conn
      :deny -> conn |> send_resp(403, Jason.encode!(%{error: "forbidden"})) |> put_resp_content_type("application/json") |> halt()
    end
  end

  defp build_subject(nil), do: %{id: nil, roles: [], attributes: %{}}

  defp build_subject(account) do
    %{id: account.id, roles: account.roles || [], attributes: Map.get(account, :attributes, %{})}
  end
end
```
