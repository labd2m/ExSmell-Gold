```elixir
defmodule Provisioning.TenantSetup do
  @moduledoc """
  Orchestrates multi-step tenant provisioning: database schema, default roles,
  seed configuration, and welcome notification delivery.
  """

  alias Provisioning.{SchemaProvisioner, RoleSeeder, ConfigSeeder, WelcomeMailer, TenantRecord}

  @type tenant_params :: %{name: String.t(), subdomain: String.t(), plan: String.t(), admin_email: String.t()}
  @type provisioning_result :: {:ok, TenantRecord.t()} | {:error, String.t()}

  @spec provision(tenant_params()) :: provisioning_result()
  def provision(%{name: name, subdomain: subdomain, plan: plan, admin_email: email} = params)
      when is_binary(name) and is_binary(subdomain) and is_binary(plan) and is_binary(email) do
    with :ok <- validate_subdomain(subdomain),
         :ok <- validate_plan(plan),
         {:ok, tenant} <- TenantRecord.create(params),
         :ok <- SchemaProvisioner.provision(tenant.id),
         :ok <- RoleSeeder.seed_defaults(tenant.id),
         :ok <- ConfigSeeder.seed_plan_defaults(tenant.id, plan),
         :ok <- WelcomeMailer.send(email, tenant) do
      {:ok, tenant}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset_error(cs)}
      :error -> {:error, "Provisioning step returned unexpected result"}
    end
  end

  @spec reprovision_schema(String.t()) :: :ok | {:error, String.t()}
  def reprovision_schema(tenant_id) when is_binary(tenant_id) do
    with {:ok, _tenant} <- TenantRecord.fetch(tenant_id) do
      SchemaProvisioner.provision(tenant_id)
    end
  end

  @spec deprovision(String.t()) :: :ok | {:error, String.t()}
  def deprovision(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant} <- TenantRecord.fetch(tenant_id),
         :ok <- SchemaProvisioner.teardown(tenant_id),
         :ok <- TenantRecord.mark_deprovisioned(tenant) do
      :ok
    end
  end

  @spec validate_subdomain(String.t()) :: :ok | {:error, String.t()}
  defp validate_subdomain(subdomain) do
    cond do
      not String.match?(subdomain, ~r/^[a-z0-9\-]{3,32}$/) ->
        {:error, "Subdomain must be 3-32 lowercase alphanumeric characters or hyphens"}

      String.starts_with?(subdomain, "-") or String.ends_with?(subdomain, "-") ->
        {:error, "Subdomain must not start or end with a hyphen"}

      subdomain in reserved_subdomains() ->
        {:error, "Subdomain '#{subdomain}' is reserved"}

      true ->
        :ok
    end
  end

  @spec validate_plan(String.t()) :: :ok | {:error, String.t()}
  defp validate_plan(plan) do
    if plan in supported_plans() do
      :ok
    else
      {:error, "Unsupported plan '#{plan}'. Available: #{Enum.join(supported_plans(), ", ")}"}
    end
  end

  @spec format_changeset_error(Ecto.Changeset.t()) :: String.t()
  defp format_changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  @spec reserved_subdomains() :: [String.t()]
  defp reserved_subdomains, do: ["www", "api", "admin", "mail", "app", "dashboard", "support"]

  @spec supported_plans() :: [String.t()]
  defp supported_plans, do: ["starter", "growth", "enterprise"]
end
```
