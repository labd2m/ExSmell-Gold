```elixir
defmodule MyApp.AccessControl.PolicyEngine do
  @moduledoc """
  Evaluates attribute-based access control (ABAC) policies against a
  typed `Request` struct. Policies are compiled from module attributes
  at startup and evaluated in priority order; the first matching policy
  wins. Unmatched requests default to `:deny`.

  Policies are expressed as plain Elixir pattern-matching functions
  rather than a custom DSL, keeping them fully debuggable in IEx.
  """

  alias MyApp.AccessControl.{Request, PolicyResult}

  @type action :: atom()
  @type resource_type :: atom()

  @type policy_fn ::
          (Request.t() -> {:allow, String.t()} | :skip)

  @policies [
    &__MODULE__.policy_system_actor/1,
    &__MODULE__.policy_owner/1,
    &__MODULE__.policy_admin_read/1,
    &__MODULE__.policy_team_member_read/1,
    &__MODULE__.policy_public_read/1
  ]

  @doc """
  Evaluates all registered policies against `request` in order.
  Returns a `PolicyResult` with `:allow` or `:deny` and the matching
  policy name, or `:no_matching_policy` for the default deny.
  """
  @spec evaluate(Request.t()) :: PolicyResult.t()
  def evaluate(%Request{} = request) do
    result =
      Enum.find_value(@policies, fn policy ->
        case policy.(request) do
          {:allow, reason} -> %PolicyResult{decision: :allow, reason: reason}
          :skip -> nil
        end
      end)

    result || %PolicyResult{decision: :deny, reason: "no_matching_policy"}
  end

  @doc "Returns `true` when `request` is allowed by any registered policy."
  @spec allowed?(Request.t()) :: boolean()
  def allowed?(%Request{} = request) do
    evaluate(request).decision == :allow
  end

  @doc false
  @spec policy_system_actor(Request.t()) :: {:allow, String.t()} | :skip
  def policy_system_actor(%Request{actor: %{type: :system}}),
    do: {:allow, "system_actor_unrestricted"}

  def policy_system_actor(_), do: :skip

  @doc false
  @spec policy_owner(Request.t()) :: {:allow, String.t()} | :skip
  def policy_owner(%Request{actor: %{id: actor_id}, resource: %{owner_id: owner_id}})
      when actor_id == owner_id,
      do: {:allow, "resource_owner"}

  def policy_owner(_), do: :skip

  @doc false
  @spec policy_admin_read(Request.t()) :: {:allow, String.t()} | :skip
  def policy_admin_read(%Request{actor: %{role: :admin}, action: action})
      when action in [:read, :list],
      do: {:allow, "admin_read"}

  def policy_admin_read(_), do: :skip

  @doc false
  @spec policy_team_member_read(Request.t()) :: {:allow, String.t()} | :skip
  def policy_team_member_read(%Request{
        actor: %{team_id: team_id},
        resource: %{team_id: resource_team_id},
        action: action
      })
      when team_id == resource_team_id and action in [:read, :list],
      do: {:allow, "team_member_read"}

  def policy_team_member_read(_), do: :skip

  @doc false
  @spec policy_public_read(Request.t()) :: {:allow, String.t()} | :skip
  def policy_public_read(%Request{resource: %{visibility: :public}, action: :read}),
    do: {:allow, "public_read"}

  def policy_public_read(_), do: :skip
end

defmodule MyApp.AccessControl.Request do
  @moduledoc "Represents an access control evaluation request."

  @enforce_keys [:actor, :action, :resource]
  defstruct [:actor, :action, :resource]

  @type t :: %__MODULE__{
          actor: map(),
          action: MyApp.AccessControl.PolicyEngine.action(),
          resource: map()
        }
end

defmodule MyApp.AccessControl.PolicyResult do
  @moduledoc "The outcome of a policy evaluation."

  @enforce_keys [:decision, :reason]
  defstruct [:decision, :reason]

  @type t :: %__MODULE__{
          decision: :allow | :deny,
          reason: String.t()
        }
end
```
