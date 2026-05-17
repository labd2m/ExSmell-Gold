# Annotated Example 14 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Platform.Tenant`
- **Affected functions:** `Platform.Tenant.provision/1` (file one) and `Platform.Tenant.deprovision/2` (file two)
- **Explanation:** `Platform.Tenant` is defined in both `lib/platform/tenant.ex` and `lib/platform/tenant_deprovisioning.ex`. Because BEAM stores modules by atom name, the second definition replaces the first on load. Tenant provisioning or deprovisioning will silently stop working depending on which file the compiler processes last.

---

```elixir
# ── file: lib/platform/tenant.ex ─────────────────────────────────────────────

defmodule Platform.Tenant do
  @moduledoc """
  Handles multi-tenant provisioning: creates isolated database schemas,
  default configurations, and seeds admin users for new platform tenants.
  """

  alias Platform.{
    SchemaProvisioner,
    ConfigStore,
    IdentityService,
    BillingIntegration,
    DNS,
    AuditLog
  }

  @default_plan :starter
  @subdomain_regex ~r/^[a-z0-9][a-z0-9\-]{1,61}[a-z0-9]$/

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          subdomain: String.t(),
          plan: atom(),
          schema_name: String.t(),
          region: String.t(),
          admin_user_id: String.t() | nil,
          status: :provisioning | :active | :suspended | :deprovisioned,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :name,
    :subdomain,
    :schema_name,
    :region,
    :admin_user_id,
    :created_at,
    plan: @default_plan,
    status: :provisioning
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Platform.Tenant` is declared again in
  # `lib/platform/tenant_deprovisioning.ex`. BEAM only allows one version per
  # name. If deprovisioning compiles second, `provision/1` is gone, preventing
  # any new tenant from being created on the platform.

  @spec provision(map()) :: {:ok, t()} | {:error, term()}
  def provision(attrs) do
    subdomain = String.downcase(attrs[:subdomain] || "")
    region = attrs[:region] || "us-east-1"

    with :ok <- validate_subdomain(subdomain),
         :ok <- check_subdomain_available(subdomain),
         {:ok, tenant_id} <- generate_tenant_id(),
         schema_name = "tenant_#{String.replace(tenant_id, "-", "_")}",
         {:ok, _schema} <- SchemaProvisioner.create(schema_name, region),
         {:ok, billing} <- BillingIntegration.create_customer(attrs) do
      tenant = %__MODULE__{
        id: tenant_id,
        name: attrs[:name],
        subdomain: subdomain,
        schema_name: schema_name,
        plan: attrs[:plan] || @default_plan,
        region: region,
        created_at: DateTime.utc_now(),
        status: :provisioning
      }

      ConfigStore.seed_defaults(tenant)
      DNS.create_cname(subdomain)

      {:ok, admin} = IdentityService.create_admin(tenant, attrs[:admin])
      tenant = %{tenant | admin_user_id: admin.id, status: :active}

      AuditLog.write(:tenant_provisioned, %{
        tenant_id: tenant.id,
        billing_customer_id: billing.id
      })

      {:ok, tenant}
    end
  end

  # VALIDATION: SMELL END

  @spec suspend(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def suspend(tenant_id, reason) do
    AuditLog.write(:tenant_suspended, %{tenant_id: tenant_id, reason: reason})
    {:ok, %{id: tenant_id, status: :suspended}}
  end

  defp validate_subdomain(sd) do
    if Regex.match?(@subdomain_regex, sd), do: :ok, else: {:error, :invalid_subdomain}
  end

  defp check_subdomain_available(sd) do
    case DNS.lookup(sd) do
      {:ok, _} -> {:error, :subdomain_taken}
      {:error, :not_found} -> :ok
    end
  end

  defp generate_tenant_id do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    {:ok, id}
  end
end


# ── file: lib/platform/tenant_deprovisioning.ex ──────────────────────────────

defmodule Platform.Tenant do
  @moduledoc """
  Manages tenant deprovisioning: suspends access, archives data, removes
  schema resources, and ensures GDPR-compliant data erasure on request.
  """

  alias Platform.{SchemaProvisioner, DNS, BillingIntegration, DataArchiver, AuditLog}

  @data_retention_days 30
  @gdpr_erasure_days 14

  @spec deprovision(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def deprovision(tenant_id, opts \\ %{}) do
    reason = Map.get(opts, :reason, :account_closed)
    retain_data = Map.get(opts, :retain_data, true)

    with {:ok, tenant} <- fetch(tenant_id),
         :ok <- validate_not_already_deprovisioned(tenant) do
      BillingIntegration.cancel_subscription(tenant.billing_customer_id)
      DNS.remove_cname(tenant.subdomain)

      if retain_data do
        DataArchiver.archive(tenant.schema_name, retention_days: @data_retention_days)
      else
        SchemaProvisioner.drop(tenant.schema_name)
      end

      updated = %{tenant | status: :deprovisioned}

      AuditLog.write(:tenant_deprovisioned, %{
        tenant_id: tenant_id,
        reason: reason,
        data_retained: retain_data
      })

      {:ok, updated}
    end
  end

  @spec erase_data(String.t()) :: :ok | {:error, term()}
  def erase_data(tenant_id) do
    with {:ok, tenant} <- fetch(tenant_id),
         :ok <- validate_deprovisioned(tenant) do
      SchemaProvisioner.drop(tenant.schema_name)

      AuditLog.write(:tenant_data_erased, %{
        tenant_id: tenant_id,
        erased_at: DateTime.utc_now(),
        compliance_framework: :gdpr
      })

      :ok
    end
  end

  @spec schedule_erasure(String.t()) :: {:ok, map()}
  def schedule_erasure(tenant_id) do
    erasure_date = Date.add(Date.utc_today(), @gdpr_erasure_days)
    AuditLog.write(:tenant_erasure_scheduled, %{tenant_id: tenant_id, scheduled_for: erasure_date})
    {:ok, %{tenant_id: tenant_id, erasure_scheduled_for: erasure_date}}
  end

  defp fetch(tenant_id), do: {:ok, %{id: tenant_id, status: :active}}

  defp validate_not_already_deprovisioned(%{status: :deprovisioned}),
    do: {:error, :already_deprovisioned}

  defp validate_not_already_deprovisioned(_), do: :ok

  defp validate_deprovisioned(%{status: :deprovisioned}), do: :ok
  defp validate_deprovisioned(_), do: {:error, :tenant_still_active}
end
```
