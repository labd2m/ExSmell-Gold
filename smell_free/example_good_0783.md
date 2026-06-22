```elixir
defmodule Policy.AccessControl do
  @moduledoc """
  A declarative, composable access policy engine. Policies are expressed as
  modules that implement the `Policy.Rule` behaviour, each returning `:allow`,
  `:deny`, or `:abstain`. The engine evaluates rules in declaration order,
  stopping at the first non-abstaining verdict. Mixing rules from multiple
  policy modules via `use Policy.AccessControl` produces a merged rule chain
  without duplicating evaluation logic.
  """

  defmacro __using__(_opts) do
    quote do
      import Policy.AccessControl, only: [defpolicy: 2]
      @rules []
      @before_compile Policy.AccessControl
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def rules, do: Enum.reverse(@rules)

      def authorize(actor, action, resource) do
        Policy.AccessControl.evaluate(rules(), actor, action, resource)
      end
    end
  end

  defmacro defpolicy(name, do: block) do
    quote do
      @rules [unquote(name) | @rules]
      def unquote(name)(var!(actor), var!(action), var!(resource)) do
        _ = var!(actor)
        _ = var!(action)
        _ = var!(resource)
        unquote(block)
      end
    end
  end

  @doc """
  Evaluates `rules` in order against `actor`, `action`, `resource`.
  Returns `:allow`, `{:deny, reason}`, or `{:deny, :no_rule_matched}`.
  """
  @spec evaluate([atom()], term(), atom(), term()) ::
          :allow | {:deny, term()}
  def evaluate(rules, actor, action, resource) when is_list(rules) do
    Enum.reduce_while(rules, {:deny, :no_rule_matched}, fn rule_fn, acc ->
      case rule_fn.(actor, action, resource) do
        :allow -> {:halt, :allow}
        {:deny, reason} -> {:halt, {:deny, reason}}
        :abstain -> {:cont, acc}
      end
    end)
  end
end

defmodule Policy.Rule do
  @moduledoc """
  Behaviour for individual access policy rules.
  """
  @callback call(actor :: term(), action :: atom(), resource :: term()) ::
              :allow | {:deny, term()} | :abstain
end

defmodule Documents.Policy do
  @moduledoc """
  Access policy for the Documents context.
  Evaluated top-to-bottom; first non-abstaining rule wins.
  """

  use Policy.AccessControl

  defpolicy :superadmin_bypass do
    if actor.role == :superadmin, do: :allow, else: :abstain
  end

  defpolicy :deny_suspended_users do
    if actor.status == :suspended, do: {:deny, :account_suspended}, else: :abstain
  end

  defpolicy :owner_full_access do
    if resource.owner_id == actor.id, do: :allow, else: :abstain
  end

  defpolicy :org_member_read do
    if action == :read and resource.organisation_id == actor.organisation_id do
      :allow
    else
      :abstain
    end
  end

  defpolicy :org_editor_write do
    if action in [:create, :update] and
         actor.role in [:editor, :admin] and
         resource.organisation_id == actor.organisation_id do
      :allow
    else
      :abstain
    end
  end

  defpolicy :deny_all do
    {:deny, :insufficient_permissions}
  end
end

defmodule Documents.PolicyEnforcer do
  @moduledoc """
  Provides `authorize/3` helpers for controllers and contexts,
  wrapping the policy engine in application-friendly return shapes.
  """

  @doc """
  Returns `:ok` when `actor` may perform `action` on `resource`,
  or `{:error, :forbidden}` otherwise.
  """
  @spec authorize(term(), atom(), term()) :: :ok | {:error, :forbidden}
  def authorize(actor, action, resource) do
    case Documents.Policy.authorize(actor, action, resource) do
      :allow -> :ok
      {:deny, reason} ->
        require Logger
        Logger.debug("Access denied", actor_id: actor.id, action: action, reason: reason)
        {:error, :forbidden}
    end
  end
end
```
