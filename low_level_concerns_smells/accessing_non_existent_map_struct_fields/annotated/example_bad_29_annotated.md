# Annotated Example 29

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `DevOps.DeploymentManager.deploy/2`, lines where `release` map keys are accessed dynamically
- **Affected function(s):** `deploy/2`
- **Short explanation:** `release[:version]`, `release[:artifact_url]`, `release[:rollback_version]`, and `release[:migration_required]` use dynamic bracket access on a plain map. When `:migration_required` is absent, `nil` is treated as falsy and database migrations are silently skipped, potentially deploying code that requires a schema change against an outdated database. A missing `:rollback_version` causes `nil` to be stored in the deployment record, making automated rollback impossible.

---

```elixir
defmodule DevOps.DeploymentManager do
  @moduledoc """
  Orchestrates application deployments across environments, including
  pre-flight checks, migration execution, artifact promotion, and
  rollback metadata recording.
  """

  require Logger

  @valid_environments  ~w(staging canary production)
  @max_artifact_url_len 1024
  @version_regex       ~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$/

  @type deployment :: %{
          id: String.t(),
          version: String.t(),
          environment: String.t(),
          artifact_url: String.t(),
          rollback_version: String.t() | nil,
          migration_ran: boolean(),
          deployed_by: String.t(),
          deployed_at: DateTime.t(),
          status: :in_progress | :success | :failed
        }

  @spec deploy(map(), map()) :: {:ok, deployment()} | {:error, String.t()}
  def deploy(release, deploy_config) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `release[:version]`,
    # `release[:artifact_url]`, `release[:rollback_version]`, and
    # `release[:migration_required]` use dynamic bracket access on a plain
    # map. When `:migration_required` is absent, `nil` is returned and
    # treated as falsy; database migrations are silently skipped, potentially
    # leaving the schema inconsistent with the new code. When
    # `:rollback_version` is absent, `nil` is stored in the deployment
    # record, disabling automated rollback without any warning to the operator.
    version            = release[:version]
    artifact_url       = release[:artifact_url]
    rollback_version   = release[:rollback_version]
    migration_required = release[:migration_required]
    # VALIDATION: SMELL END

    environment = Map.fetch!(deploy_config, :environment)
    deployed_by = Map.get(deploy_config, :initiated_by, "system")

    with :ok <- validate_environment(environment),
         :ok <- validate_version(version),
         :ok <- validate_artifact_url(artifact_url) do
      deployment = %{
        id: generate_id(),
        version: version,
        environment: environment,
        artifact_url: artifact_url,
        rollback_version: rollback_version,
        migration_ran: false,
        deployed_by: deployed_by,
        deployed_at: DateTime.utc_now(),
        status: :in_progress
      }

      Logger.info("Deployment started",
        deployment_id: deployment.id,
        version: version,
        environment: environment,
        deployed_by: deployed_by
      )

      deployment = run_preflight(deployment, deploy_config)
      deployment = maybe_run_migrations(deployment, migration_required)
      deployment = promote_artifact(deployment)

      final = %{deployment | status: :success}

      Logger.info("Deployment succeeded",
        deployment_id: final.id,
        version: version,
        environment: environment,
        migration_ran: final.migration_ran,
        rollback_available: not is_nil(rollback_version)
      )

      {:ok, final}
    end
  rescue
    e ->
      Logger.error("Deployment failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ── Pipeline steps ───────────────────────────────────────────────────────────

  defp run_preflight(deployment, config) do
    checks = Map.get(config, :preflight_checks, [:health, :disk_space])
    Logger.debug("Running preflight checks: #{inspect(checks)}")
    deployment
  end

  defp maybe_run_migrations(deployment, migration_required) do
    if migration_required do
      Logger.info("Running database migrations", deployment_id: deployment.id)
      %{deployment | migration_ran: true}
    else
      Logger.debug("No migrations required for this release")
      deployment
    end
  end

  defp promote_artifact(deployment) do
    Logger.info("Promoting artifact",
      deployment_id: deployment.id,
      artifact_url: deployment.artifact_url
    )
    deployment
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_environment(env) when env in @valid_environments, do: :ok

  defp validate_environment(env),
    do: {:error, "Invalid environment: #{env}. Valid: #{Enum.join(@valid_environments, ", ")}"}

  defp validate_version(nil), do: {:error, "Release version is required"}

  defp validate_version(v) do
    if Regex.match?(@version_regex, v) do
      :ok
    else
      {:error, "Version must follow semver format (e.g. 1.2.3), got: #{v}"}
    end
  end

  defp validate_artifact_url(nil), do: {:error, "Artifact URL is required"}

  defp validate_artifact_url(url) when byte_size(url) > @max_artifact_url_len,
    do: {:error, "Artifact URL exceeds #{@max_artifact_url_len} characters"}

  defp validate_artifact_url(url) do
    if String.starts_with?(url, ["https://", "s3://", "gs://"]) do
      :ok
    else
      {:error, "Artifact URL must use https://, s3://, or gs:// scheme, got: #{url}"}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
```
