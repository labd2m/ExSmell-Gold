```elixir
defmodule MyApp.Platform.CapabilityMatrix do
  @moduledoc """
  Evaluates which platform capabilities are accessible to a given user
  based on their subscription plan and the features enabled for their
  organisation. Capability checks are designed to be used at both the
  HTTP boundary (Plug) and inside business logic functions, so the module
  exposes a simple, dependency-free predicate API.

  Capabilities are defined as atoms in `@all_capabilities` and grouped
  by the minimum plan required. This compile-time definition means that
  adding a new capability is a single-line change with no database
  migration required.
  """

  @plan_hierarchy [:free, :starter, :pro, :enterprise]

  @plan_capabilities %{
    free: [:read_reports, :manage_own_profile, :basic_api],
    starter: [:team_members, :csv_export, :webhooks, :standard_api],
    pro: [:advanced_reports, :bulk_import, :custom_domains, :full_api, :audit_log],
    enterprise: [:sso, :saml, :dedicated_support, :custom_contracts, :unlimited_api]
  }

  @type plan :: :free | :starter | :pro | :enterprise
  @type capability :: atom()
  @type context :: %{
          required(:plan) => plan(),
          optional(:org_features) => [capability()],
          optional(:user_role) => atom()
        }

  @doc """
  Returns `true` when `capability` is available in `context`. A
  capability is available when it is included in the plan's feature set
  or explicitly granted via `org_features`.
  """
  @spec has?(capability(), context()) :: boolean()
  def has?(capability, %{plan: plan} = context) when is_atom(capability) do
    plan_includes?(plan, capability) or org_override?(context, capability)
  end

  @doc """
  Returns all capabilities available in `context`, combining plan
  entitlements with organisation-level overrides.
  """
  @spec available(context()) :: [capability()]
  def available(%{plan: plan} = context) do
    plan_features = capabilities_for_plan(plan)
    org_features = Map.get(context, :org_features, [])
    (plan_features ++ org_features) |> Enum.uniq()
  end

  @doc """
  Returns `{:ok, :allowed}` or `{:error, :capability_required, capability}`
  for use in `with` pipelines inside controllers and context modules.
  """
  @spec require(capability(), context()) ::
          {:ok, :allowed} | {:error, :capability_required, capability()}
  def require(capability, context) do
    if has?(capability, context),
      do: {:ok, :allowed},
      else: {:error, :capability_required, capability}
  end

  @doc "Returns `true` when `plan_a` is at or above `plan_b` in the hierarchy."
  @spec plan_gte?(plan(), plan()) :: boolean()
  def plan_gte?(plan_a, plan_b) do
    plan_rank(plan_a) >= plan_rank(plan_b)
  end

  @doc "Returns the capabilities uniquely available at each plan tier above `current_plan`."
  @spec upgrade_preview(plan()) :: %{plan() => [capability()]}
  def upgrade_preview(current_plan) do
    @plan_hierarchy
    |> Enum.drop_while(&(&1 != current_plan))
    |> Enum.drop(1)
    |> Map.new(fn plan ->
      new_capabilities = @plan_capabilities[plan] || []
      {plan, new_capabilities}
    end)
  end

  @spec plan_includes?(plan(), capability()) :: boolean()
  defp plan_includes?(plan, capability) do
    capability in capabilities_for_plan(plan)
  end

  @spec capabilities_for_plan(plan()) :: [capability()]
  defp capabilities_for_plan(plan) do
    @plan_hierarchy
    |> Enum.take_while(&(&1 != plan))
    |> Kernel.++([plan])
    |> Enum.flat_map(&(@plan_capabilities[&1] || []))
  end

  @spec org_override?(context(), capability()) :: boolean()
  defp org_override?(context, capability) do
    context
    |> Map.get(:org_features, [])
    |> Enum.member?(capability)
  end

  @spec plan_rank(plan()) :: non_neg_integer()
  defp plan_rank(plan) do
    Enum.find_index(@plan_hierarchy, &(&1 == plan)) || 0
  end
end
```
