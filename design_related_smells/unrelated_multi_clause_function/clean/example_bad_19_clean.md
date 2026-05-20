```elixir
defmodule TenantProvisioner do
  @moduledoc """
  Manages tenant lifecycle provisioning for the multi-tenant SaaS platform.
  Handles tenant creation, plan upgrades, and tenant deactivation/offboarding.
  """

  alias TenantProvisioner.{
    OnboardingRequest,
    UpgradeRequest,
    OffboardingRequest,
    TenantStore,
    DatabaseProvisioner,
    BillingService,
    DNSManager,
    FeatureToggler,
    DataExporter,
    Mailer,
    AuditLog
  }

  require Logger

  @doc """
  Provision a tenant lifecycle event.

  Accepts a `%OnboardingRequest{}`, `%UpgradeRequest{}`, or `%OffboardingRequest{}`
  and performs the appropriate infrastructure and data operations.

  ## Examples

      iex> TenantProvisioner.provision(%OnboardingRequest{org_name: "Acme", plan: :starter})
      {:ok, %Tenant{id: "ten_001", subdomain: "acme"}}

  """

  def provision(%OnboardingRequest{
        org_name: org_name,
        admin_email: admin_email,
        plan: plan,
        region: region
      }) do
    subdomain = slugify(org_name)

    with :ok <- validate_subdomain_available(subdomain),
         {:ok, tenant} <-
           TenantStore.create(%{
             name: org_name,
             subdomain: subdomain,
             admin_email: admin_email,
             plan: plan,
             region: region,
             status: :provisioning
           }),
         {:ok, db_url} <- DatabaseProvisioner.provision(tenant.id, region),
         :ok <- DNSManager.create_subdomain_record(subdomain, region),
         :ok <- FeatureToggler.apply_plan_features(tenant.id, plan),
         {:ok, updated} <-
           TenantStore.update(tenant.id, %{database_url: db_url, status: :active}),
         :ok <- Mailer.send_welcome(admin_email, updated) do
      Logger.info("Tenant #{tenant.id} (#{subdomain}) provisioned on plan #{plan}")
      {:ok, updated}
    end
  end

  # provision plan upgrade for existing tenant
  def provision(%UpgradeRequest{
        tenant_id: tenant_id,
        new_plan: new_plan,
        billing_cycle: billing_cycle,
        requested_by: requested_by
      }) do
    with {:ok, tenant} <- TenantStore.find(tenant_id),
         :ok <- validate_upgrade_path(tenant.plan, new_plan),
         {:ok, subscription} <-
           BillingService.update_subscription(tenant.billing_subscription_id, %{
             plan: new_plan,
             cycle: billing_cycle
           }),
         :ok <- FeatureToggler.apply_plan_features(tenant_id, new_plan),
         {:ok, updated} <- TenantStore.update(tenant_id, %{plan: new_plan}),
         :ok <-
           AuditLog.append(:plan_upgraded, %{
             tenant_id: tenant_id,
             from: tenant.plan,
             to: new_plan,
             by: requested_by
           }),
         :ok <- Mailer.send_upgrade_confirmation(tenant.admin_email, new_plan, subscription) do
      Logger.info("Tenant #{tenant_id} upgraded from #{tenant.plan} to #{new_plan}")
      {:ok, updated}
    end
  end

  # provision tenant offboarding including data export and resource teardown
  def provision(%OffboardingRequest{
        tenant_id: tenant_id,
        reason: reason,
        export_data: export_data,
        requested_by: requested_by
      }) do
    with {:ok, tenant} <- TenantStore.find(tenant_id),
         {:ok, export_url} <- maybe_export_data(export_data, tenant),
         :ok <- BillingService.cancel_subscription(tenant.billing_subscription_id),
         :ok <- DNSManager.remove_subdomain_record(tenant.subdomain),
         :ok <- DatabaseProvisioner.teardown(tenant_id),
         {:ok, _} <- TenantStore.update(tenant_id, %{status: :offboarded, offboarded_at: DateTime.utc_now()}),
         :ok <-
           AuditLog.append(:tenant_offboarded, %{
             tenant_id: tenant_id,
             reason: reason,
             by: requested_by
           }),
         :ok <- Mailer.send_offboarding_summary(tenant.admin_email, export_url) do
      Logger.info("Tenant #{tenant_id} offboarded: #{reason}")
      {:ok, :offboarded}
    end
  end


  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp validate_subdomain_available(subdomain) do
    case TenantStore.find_by_subdomain(subdomain) do
      {:ok, _} -> {:error, :subdomain_taken}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_upgrade_path(current, new_plan) do
    order = [:free, :starter, :professional, :enterprise]
    curr_idx = Enum.find_index(order, &(&1 == current))
    new_idx = Enum.find_index(order, &(&1 == new_plan))

    if new_idx > curr_idx, do: :ok, else: {:error, :invalid_upgrade_path}
  end

  defp maybe_export_data(true, tenant) do
    DataExporter.export_tenant_data(tenant.id)
  end

  defp maybe_export_data(false, _tenant), do: {:ok, nil}
end
```
