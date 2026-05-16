```elixir
defmodule DataExport.TenantExporter do
  alias DataExport.{
    Repo,
    Tenant,
    AuthorizationPolicy,
    RateLimiter,
    DataAggregator,
    FormatConverter,
    Encryptor,
    DeliveryService
  }

  require Logger

  @supported_formats [:json, :csv, :parquet]

  def export_tenant_data(tenant_id, requester_id, opts) do
    format = Keyword.get(opts, :format, :json)
    destination = Keyword.get(opts, :destination, :email)

    with {:ok, tenant} <- fetch_tenant(tenant_id),
         :ok <- AuthorizationPolicy.authorize(requester_id, tenant, :data_export),
         :ok <- RateLimiter.check(:data_export, tenant_id),
         {:ok, raw_data} <- DataAggregator.collect(tenant),
         {:ok, converted} <- FormatConverter.convert(raw_data, format),
         {:ok, encrypted} <- Encryptor.encrypt(converted, tenant.encryption_key_id),
         {:ok, delivery_ref} <- DeliveryService.send(encrypted, destination, requester_id) do
      Logger.info(
        "Data export delivered for tenant #{tenant_id} to #{destination} " <>
          "by requester #{requester_id} (format=#{format} ref=#{delivery_ref})"
      )

      {:ok, %{delivery_ref: delivery_ref, format: format}}
    else
      {:error, :tenant_not_found} ->
        Logger.warning("Tenant #{tenant_id} not found for export request")
        {:error, :tenant_not_found}

      {:error, :unauthorized} ->
        Logger.warning("Requester #{requester_id} is not authorized to export tenant #{tenant_id}")
        {:error, :access_denied}

      {:error, :rate_limit_exceeded} ->
        Logger.warning("Data export rate limit exceeded for tenant #{tenant_id}")
        {:error, :rate_limited}

      {:error, :aggregation_error} ->
        Logger.error("Data aggregation failed for tenant #{tenant_id}")
        {:error, :data_unavailable}

      {:error, :unsupported_format} ->
        Logger.warning("Unsupported export format #{format} for tenant #{tenant_id}")
        {:error, :unsupported_format}

      {:error, {:conversion_error, reason}} ->
        Logger.error("Format conversion failed for tenant #{tenant_id}: #{inspect(reason)}")
        {:error, :conversion_failed}

      {:error, :encryption_failed} ->
        Logger.error("Encryption failed for tenant #{tenant_id} export")
        {:error, :security_error}

      {:error, :delivery_failed} ->
        Logger.error("Delivery failed for tenant #{tenant_id} export to #{destination}")
        {:error, :delivery_error}
    end
  end

  defp fetch_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :tenant_not_found}
      tenant -> {:ok, tenant}
    end
  end
end
```
