```elixir
defmodule DataPlatform.DatasetExporter do
  @moduledoc """
  Exports datasets on demand: access control, query execution,
  format transformation, upload to object storage, and signed URL generation.
  """

  alias DataPlatform.{
    AccessPolicy,
    QueryRunner,
    FormatTransformer,
    ObjectStore,
    UrlSigner
  }

  require Logger

  @allowed_formats ~w(csv json parquet)a
  @max_rows 1_000_000

  @doc """
  Exports `dataset_id` in the specified `format` for the requesting `requester`.

  `requester` must be a map with at least `:id` and `:roles`.

  Returns `{:ok, signed_url}` or a descriptive error.
  """
  @spec export_dataset(String.t(), map(), atom()) ::
          {:ok, String.t()}
          | {:error, :access_denied}
          | {:error, :query_failed, String.t()}
          | {:error, :format_unsupported}
          | {:error, :upload_failed}
          | {:error, :signing_failed}
  def export_dataset(dataset_id, requester, format) do
    unless format in @allowed_formats do
      {:error, :format_unsupported}
    else
      with :ok            <- AccessPolicy.assert_can_export(requester, dataset_id),
           {:ok, rows}    <- QueryRunner.run(dataset_id, limit: @max_rows),
           {:ok, content} <- FormatTransformer.transform(rows, format),
           {:ok, object}  <- ObjectStore.upload("exports/#{dataset_id}/#{format}", content),
           {:ok, url}     <- UrlSigner.sign(object.key, ttl_seconds: 3600) do
        Logger.info("Dataset #{dataset_id} exported as #{format} by #{requester.id}")
        {:ok, url}
      else
        {:denied, reason} ->
          Logger.warn("Export denied for #{requester.id} on #{dataset_id}: #{reason}")
          {:error, :access_denied}

        {:error, :query, detail} ->
          Logger.error("Query failed for #{dataset_id}: #{inspect(detail)}")
          {:error, :query_failed, inspect(detail)}

        {:error, :upload, reason} ->
          Logger.error("Upload failed: #{inspect(reason)}")
          {:error, :upload_failed}

        {:error, :sign} ->
          Logger.error("URL signing failed for exported object")
          {:error, :signing_failed}
      end
    end
  end
end
```
