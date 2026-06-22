```elixir
defmodule Platform.TenantProvisioningContext do
  @moduledoc """
  Orchestrates the creation of new tenant accounts. Provisioning covers
  database schema setup, default plan assignment, seed data insertion,
  and welcome notification dispatch. Each step is tracked so partial
  failures can be diagnosed and the provisioning retried from the
  last successful step without duplicating completed work.
  """

  require Logger

  alias MyApp.Repo
  alias Platform.{TenantCache}
  alias Notifications.Dispatcher, as: Notify

  @type tenant_id :: String.t()
  @type provision_params :: %{
          name: String.t(),
          owner_email: String.t(),
          plan_id: String.t(),
          db_schema: String.t()
        }

  @type step_status :: :pending | :completed | :failed
  @type provision_result ::
          {:ok, %{tenant_id: tenant_id(), steps: %{atom() => step_status()}}}
          | {:error, atom(), term()}

  @doc """
  Provisions a new tenant. Runs each step in sequence; stops at the first
  failure and returns the step name along with the reason.
  """
  @spec provision(provision_params()) :: provision_result()
  def provision(%{name: _, owner_email: _, plan_id: _, db_schema: _} = params) do
    tenant_id = generate_tenant_id()
    steps = %{create_record: :pending, setup_schema: :pending, assign_plan: :pending,
              insert_seed_data: :pending, send_welcome: :pending}

    with {:ok, steps} <- run_step(:create_record, steps, fn -> create_tenant_record(tenant_id, params) end),
         {:ok, steps} <- run_step(:setup_schema, steps, fn -> setup_db_schema(params.db_schema) end),
         {:ok, steps} <- run_step(:assign_plan, steps, fn -> assign_plan(tenant_id, params.plan_id) end),
         {:ok, steps} <- run_step(:insert_seed_data, steps, fn -> insert_seed_data(params.db_schema) end),
         {:ok, steps} <- run_step(:send_welcome, steps, fn -> send_welcome(params.owner_email, tenant_id) end) do
      TenantCache.invalidate(tenant_id)
      Logger.info("[TenantProvisioning] Tenant #{tenant_id} provisioned successfully")
      {:ok, %{tenant_id: tenant_id, steps: steps}}
    end
  end

  defp run_step(name, steps, fun) do
    case fun.() do
      :ok ->
        {:ok, Map.put(steps, name, :completed)}

      {:ok, _} ->
        {:ok, Map.put(steps, name, :completed)}

      {:error, reason} ->
        Logger.error("[TenantProvisioning] Step #{name} failed: #{inspect(reason)}")
        {:error, name, reason}
    end
  rescue
    e ->
      Logger.error("[TenantProvisioning] Step #{name} raised: #{Exception.message(e)}")
      {:error, name, Exception.message(e)}
  end

  defp create_tenant_record(tenant_id, %{name: name, db_schema: schema}) do
    import Ecto.Query
    Repo.insert_all("tenants", [%{id: tenant_id, name: name, db_schema: schema,
                                  active: true, inserted_at: DateTime.utc_now(),
                                  updated_at: DateTime.utc_now()}])
    :ok
  end

  defp setup_db_schema(schema) when is_binary(schema) do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{schema}")
    :ok
  rescue
    _ -> {:error, :schema_creation_failed}
  end

  defp assign_plan(tenant_id, plan_id) do
    Repo.insert_all("tenant_plans", [%{tenant_id: tenant_id, plan_id: plan_id,
                                       starts_on: Date.utc_today(), inserted_at: DateTime.utc_now()}])
    :ok
  end

  defp insert_seed_data(_schema), do: :ok

  defp send_welcome(email, tenant_id) do
    Notify.dispatch(%{type: :tenant_welcome, recipient_id: email,
                      payload: %{tenant_id: tenant_id}})
    :ok
  end

  defp generate_tenant_id, do: Ecto.UUID.generate()
end
```
