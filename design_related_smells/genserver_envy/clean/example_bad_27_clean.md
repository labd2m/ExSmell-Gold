```elixir
defmodule MyApp.TenantConfigAgent do
  @moduledoc """
  Manages per-tenant runtime configuration with validation,
  versioning, deployment, and rollback capabilities.
  """

  use Agent

  alias MyApp.{Repo, ConfigValidator, AuditLog, Mailer}
  alias MyApp.Config.{TenantConfig, ConfigVersion, DeploymentRecord}

  @max_versions_kept 10

  def start_link(_opts) do
    configs =
      Repo.all(TenantConfig)
      |> Enum.into(%{}, &{&1.tenant_id, &1})

    Agent.start_link(fn -> %{configs: configs, versions: %{}, deployments: %{}} end,
      name: __MODULE__)
  end

  def get_config(tenant_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.configs, tenant_id) end)
  end

  def get_version_history(tenant_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.versions, tenant_id, []) end)
  end

  def update_config(tenant_id, changes, updated_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.configs, tenant_id) do
        :error ->
          {{:error, :tenant_not_found}, state}

        {:ok, current_config} ->
          proposed = Map.merge(current_config.settings, changes)

          case ConfigValidator.validate(proposed, current_config.schema_version) do
            {:error, errors} ->
              {{:error, {:validation_failed, errors}}, state}

            :ok ->
              version = %ConfigVersion{
                id: Ecto.UUID.generate(),
                tenant_id: tenant_id,
                settings_snapshot: current_config.settings,
                version_number: current_config.version + 1,
                created_by: updated_by,
                created_at: DateTime.utc_now()
              }

              existing_versions = Map.get(state.versions, tenant_id, [])

              pruned_versions =
                [version | existing_versions]
                |> Enum.take(@max_versions_kept)

              updated_config = %{
                current_config
                | settings: proposed,
                  version: version.version_number,
                  updated_by: updated_by,
                  updated_at: DateTime.utc_now(),
                  deployed: false
              }

              Repo.insert!(version)
              Repo.update!(updated_config)
              AuditLog.record(:config_updated, %{tenant_id: tenant_id, by: updated_by})

              new_state = %{
                state
                | configs: Map.put(state.configs, tenant_id, updated_config),
                  versions: Map.put(state.versions, tenant_id, pruned_versions)
              }

              {{:ok, updated_config}, new_state}
          end
      end
    end)
  end

  def deploy_config(tenant_id, deployed_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.configs, tenant_id) do
        :error ->
          {{:error, :tenant_not_found}, state}

        {:ok, %{deployed: true}} ->
          {{:error, :already_deployed}, state}

        {:ok, config} ->
          deployment = %DeploymentRecord{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            config_version: config.version,
            deployed_by: deployed_by,
            deployed_at: DateTime.utc_now()
          }

          Repo.insert!(deployment)
          updated_config = %{config | deployed: true}
          Repo.update!(updated_config)
          AuditLog.record(:config_deployed, %{tenant_id: tenant_id, version: config.version})
          Mailer.notify_config_deployed(tenant_id, config.version)

          new_state = %{
            state
            | configs: Map.put(state.configs, tenant_id, updated_config),
              deployments: Map.update(state.deployments, tenant_id, [deployment], &[deployment | &1])
          }

          {{:ok, deployment}, new_state}
      end
    end)
  end

  def rollback_config(tenant_id, target_version_number) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, current} <- Map.fetch(state.configs, tenant_id),
           versions <- Map.get(state.versions, tenant_id, []),
           {:ok, target_version} <-
             Enum.find(versions, &(&1.version_number == target_version_number))
             |> then(fn
               nil -> :error
               v -> {:ok, v}
             end) do
        rolled_back = %{
          current
          | settings: target_version.settings_snapshot,
            version: current.version + 1,
            deployed: false,
            updated_at: DateTime.utc_now()
        }

        Repo.update!(rolled_back)
        AuditLog.record(:config_rolled_back, %{tenant_id: tenant_id, to: target_version_number})
        Mailer.notify_config_rollback(tenant_id, target_version_number)

        {{:ok, rolled_back}, put_in(state, [:configs, tenant_id], rolled_back)}
      else
        :error -> {{:error, :not_found}, state}
      end
    end)
  end

  def list_tenants_with_undeployed_changes do
    Agent.get(__MODULE__, fn state ->
      state.configs
      |> Map.values()
      |> Enum.filter(&(not &1.deployed))
      |> Enum.map(& &1.tenant_id)
    end)
  end
end
```
