```elixir
defmodule Platform.TenantAdmin do
  @moduledoc """
  Administers tenant accounts: provisioning, billing configuration, and access control.
  """

  alias Platform.Repo
  alias Platform.Tenants.Tenant
  alias Platform.Billing.TenantPlan
  alias Platform.Billing.UsageOverage
  alias Platform.Billing.Invoice
  alias Platform.RBAC.RoleAssignment
  alias Platform.RBAC.Permission

  import Ecto.Query
  require Logger



  @doc "Provisions a new tenant and initializes their default configuration."
  @spec provision_tenant(map()) :: {:ok, Tenant.t()} | {:error, term()}
  def provision_tenant(attrs) do
    Repo.transaction(fn ->
      tenant_attrs = %{
        name: attrs[:name],
        slug: slugify(attrs[:name]),
        owner_email: attrs[:owner_email],
        plan: :trial,
        status: :active,
        provisioned_at: DateTime.utc_now(),
        settings: default_settings()
      }

      case Repo.insert(Tenant.changeset(%Tenant{}, tenant_attrs)) do
        {:ok, tenant} ->
          Logger.info("Tenant provisioned: #{tenant.slug} (id=#{tenant.id})")
          tenant

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Suspends a tenant account, disabling all member access."
  @spec suspend_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def suspend_tenant(%Tenant{status: :active} = tenant) do
    tenant
    |> Tenant.changeset(%{status: :suspended, suspended_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def suspend_tenant(%Tenant{}), do: {:error, :not_active}

  @doc "Applies new configuration settings to a tenant (feature flags, limits, etc.)."
  @spec update_tenant_settings(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, term()}
  def update_tenant_settings(%Tenant{} = tenant, new_settings) do
    merged = Map.merge(tenant.settings, new_settings)

    tenant
    |> Tenant.changeset(%{settings: merged})
    |> Repo.update()
  end


  @doc "Assigns a billing plan to a tenant, replacing any existing plan."
  @spec set_billing_plan(Tenant.t(), atom()) :: {:ok, TenantPlan.t()} | {:error, term()}
  def set_billing_plan(%Tenant{id: tenant_id}, plan_name) do
    attrs = %{
      tenant_id: tenant_id,
      plan: plan_name,
      assigned_at: DateTime.utc_now(),
      active: true
    }

    Repo.transaction(fn ->
      TenantPlan
      |> where([p], p.tenant_id == ^tenant_id and p.active == true)
      |> Repo.update_all(set: [active: false])

      %TenantPlan{} |> TenantPlan.changeset(attrs) |> Repo.insert!()
    end)
  end

  @doc "Records a usage overage event when a tenant exceeds their plan limits."
  @spec record_usage_overage(Tenant.t(), map()) ::
          {:ok, UsageOverage.t()} | {:error, term()}
  def record_usage_overage(%Tenant{id: tenant_id}, %{metric: metric, overage_units: units}) do
    attrs = %{
      tenant_id: tenant_id,
      metric: metric,
      overage_units: units,
      recorded_at: DateTime.utc_now()
    }

    %UsageOverage{} |> UsageOverage.changeset(attrs) |> Repo.insert()
  end

  @doc "Generates a usage overage invoice for the current billing period."
  @spec generate_usage_invoice(Tenant.t()) :: {:ok, Invoice.t()} | {:error, term()}
  def generate_usage_invoice(%Tenant{id: tenant_id}) do
    overages =
      UsageOverage
      |> where([u], u.tenant_id == ^tenant_id and is_nil(u.invoiced_at))
      |> Repo.all()

    total_cents = Enum.sum(Enum.map(overages, &overage_cost_cents/1))

    if total_cents > 0 do
      now = DateTime.utc_now()

      {:ok, invoice} =
        %Invoice{}
        |> Invoice.changeset(%{
          tenant_id: tenant_id,
          amount_cents: total_cents,
          description: "Usage overages",
          issued_at: now
        })
        |> Repo.insert()

      overage_ids = Enum.map(overages, & &1.id)

      UsageOverage
      |> where([u], u.id in ^overage_ids)
      |> Repo.update_all(set: [invoiced_at: now])

      {:ok, invoice}
    else
      {:error, :no_overages}
    end
  end


  @doc "Assigns a named role to a user within a specific tenant."
  @spec assign_role(String.t(), String.t(), atom()) ::
          {:ok, RoleAssignment.t()} | {:error, term()}
  def assign_role(tenant_id, user_id, role) do
    attrs = %{
      tenant_id: tenant_id,
      user_id: user_id,
      role: role,
      assigned_at: DateTime.utc_now()
    }

    %RoleAssignment{}
    |> RoleAssignment.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc "Revokes a user's role within a tenant."
  @spec revoke_role(String.t(), String.t(), atom()) :: :ok | {:error, :not_found}
  def revoke_role(tenant_id, user_id, role) do
    case Repo.get_by(RoleAssignment, tenant_id: tenant_id, user_id: user_id, role: role) do
      nil -> {:error, :not_found}
      assignment -> Repo.delete!(assignment) && :ok
    end
  end

  @doc "Returns the effective permission set for a user in a tenant."
  @spec list_permissions(String.t(), String.t()) :: [atom()]
  def list_permissions(tenant_id, user_id) do
    RoleAssignment
    |> where([r], r.tenant_id == ^tenant_id and r.user_id == ^user_id)
    |> Repo.all()
    |> Enum.flat_map(fn %{role: role} -> permissions_for_role(role) end)
    |> Enum.uniq()
  end


  defp slugify(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
  defp default_settings, do: %{max_users: 5, max_projects: 3, sso_enabled: false}

  defp overage_cost_cents(%{metric: :api_calls, overage_units: u}), do: u * 1
  defp overage_cost_cents(%{metric: :storage_gb, overage_units: u}), do: u * 50
  defp overage_cost_cents(_), do: 0

  defp permissions_for_role(:admin), do: [:read, :write, :delete, :manage_users, :billing]
  defp permissions_for_role(:member), do: [:read, :write]
  defp permissions_for_role(:viewer), do: [:read]
  defp permissions_for_role(_), do: []

end
```
