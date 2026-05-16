# Annotated Example 49 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `provision_workspace/2`, inside the `with` expression's `else` block
- **Affected function(s):** `provision_workspace/2`
- **Short explanation:** Six provisioning steps produce six structurally distinct failure shapes. Placing every failure case into a single flat `else` block erases the one-to-one relationship between a pipeline step and the errors it can emit, making the function harder to debug and extend.

---

```elixir
defmodule Platform.WorkspaceProvisioner do
  @moduledoc """
  Provisions a new multi-tenant workspace: plan validation, organisation
  creation, infrastructure allocation, default role seeding, billing
  account setup, and owner invitation dispatch.
  """

  alias Platform.{
    PlanRegistry,
    OrganisationRepo,
    InfrastructureAllocator,
    RoleSeeder,
    BillingAccountService,
    InvitationMailer
  }

  require Logger

  @doc """
  Provisions a new workspace for `owner_email` under the given `params`.

  Expected params: `:plan`, `:workspace_name`, `:region`.

  Returns `{:ok, workspace}` or a structured error.
  """
  @spec provision_workspace(String.t(), map()) ::
          {:ok, map()}
          | {:error, :invalid_plan}
          | {:error, :name_taken}
          | {:error, :infrastructure_failed, String.t()}
          | {:error, :role_seed_failed}
          | {:error, :billing_setup_failed}
          | {:error, :invitation_failed}
  def provision_workspace(owner_email, params) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because six with-clauses each fail with a
    # structurally different shape ({:error, :not_found}, {:error, :conflict},
    # {:error, :infra, _}, {:error, :seed, _}, {:error, :billing, _},
    # {:error, :mail}). The single else block collapses all six into one
    # undifferentiated list, making step-to-error attribution opaque.
    with {:ok, plan}      <- PlanRegistry.fetch(params.plan),
         {:ok, org}       <- OrganisationRepo.create(%{
                               name:       params.workspace_name,
                               plan_id:    plan.id,
                               region:     params.region,
                               created_at: DateTime.utc_now()
                             }),
         {:ok, infra}     <- InfrastructureAllocator.allocate(org.id, params.region, plan.tier),
         {:ok, _roles}    <- RoleSeeder.seed_defaults(org.id),
         {:ok, billing}   <- BillingAccountService.setup(org.id, owner_email, plan),
         :ok              <- InvitationMailer.send_owner_invite(owner_email, org, billing) do
      workspace = %{
        id:             org.id,
        name:           org.name,
        plan:           plan.slug,
        region:         params.region,
        infra_endpoint: infra.endpoint,
        billing_id:     billing.id,
        provisioned_at: DateTime.utc_now()
      }

      Logger.info("Workspace #{org.id} provisioned for #{owner_email} on plan #{plan.slug}")
      {:ok, workspace}
    else
      {:error, :not_found} ->
        Logger.warn("Plan #{params.plan} not found in registry")
        {:error, :invalid_plan}

      {:error, :conflict} ->
        Logger.info("Workspace name '#{params.workspace_name}' is already taken")
        {:error, :name_taken}

      {:error, :infra, detail} ->
        Logger.error("Infrastructure allocation failed: #{inspect(detail)}")
        {:error, :infrastructure_failed, inspect(detail)}

      {:error, :seed, detail} ->
        Logger.error("Role seeding failed for org: #{inspect(detail)}")
        {:error, :role_seed_failed}

      {:error, :billing, reason} ->
        Logger.error("Billing account setup failed: #{inspect(reason)}")
        {:error, :billing_setup_failed}

      {:error, :mail} ->
        Logger.error("Owner invitation email failed for #{owner_email}")
        {:error, :invitation_failed}
    end
    # VALIDATION: SMELL END
  end
end
```
