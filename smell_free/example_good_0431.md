```elixir
defmodule Pipelines.StageConfig do
  @moduledoc """
  Defines and validates the configuration schema for data pipeline stages.
  Each stage type has a distinct configuration struct with explicit fields
  and a dedicated validation function. Validation is centralised here so
  pipeline builders get clear, field-level error messages at construction
  time rather than cryptic runtime failures during execution.
  """

  @type http_source_config :: %{
          url: binary(),
          method: :get | :post,
          headers: [{binary(), binary()}],
          timeout_ms: pos_integer(),
          retry_count: non_neg_integer()
        }

  @type sql_source_config :: %{
          query: binary(),
          repo: module(),
          chunk_size: pos_integer()
        }

  @type transform_config :: %{
          module: module(),
          function: atom(),
          args: list()
        }

  @type sink_config :: %{
          type: :s3 | :postgres | :http,
          options: map()
        }

  @doc """
  Validates and normalises an HTTP source configuration map.
  Returns `{:ok, config}` or `{:error, [field_error]}`.
  """
  @spec validate_http_source(map()) :: {:ok, http_source_config()} | {:error, [binary()]}
  def validate_http_source(attrs) when is_map(attrs) do
    errors =
      []
      |> check_required(attrs, :url, &is_binary/1, "must be a binary URL")
      |> check_required(attrs, :method, &(&1 in [:get, :post]), "must be :get or :post")
      |> check_optional(attrs, :timeout_ms, &(is_integer(&1) and &1 > 0), "must be a positive integer")
      |> check_optional(attrs, :retry_count, &(is_integer(&1) and &1 >= 0), "must be a non-negative integer")

    if errors == [] do
      config = %{
        url: attrs.url,
        method: attrs.method,
        headers: Map.get(attrs, :headers, []),
        timeout_ms: Map.get(attrs, :timeout_ms, 10_000),
        retry_count: Map.get(attrs, :retry_count, 3)
      }

      {:ok, config}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates a SQL source configuration map.
  """
  @spec validate_sql_source(map()) :: {:ok, sql_source_config()} | {:error, [binary()]}
  def validate_sql_source(attrs) when is_map(attrs) do
    errors =
      []
      |> check_required(attrs, :query, &(is_binary(&1) and byte_size(&1) > 0), "must be a non-empty query string")
      |> check_required(attrs, :repo, &(is_atom(&1) and Code.ensure_loaded?(&1)), "must be a loaded module")
      |> check_optional(attrs, :chunk_size, &(is_integer(&1) and &1 > 0), "must be a positive integer")

    if errors == [] do
      {:ok, %{query: attrs.query, repo: attrs.repo, chunk_size: Map.get(attrs, :chunk_size, 500)}}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates a transform stage configuration.
  """
  @spec validate_transform(map()) :: {:ok, transform_config()} | {:error, [binary()]}
  def validate_transform(attrs) when is_map(attrs) do
    errors =
      []
      |> check_required(attrs, :module, &(is_atom(&1) and Code.ensure_loaded?(&1)), "must be a loaded module")
      |> check_required(attrs, :function, &is_atom/1, "must be an atom")

    if errors == [] do
      {:ok, %{module: attrs.module, function: attrs.function, args: Map.get(attrs, :args, [])}}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates a sink configuration, dispatching to the type-specific validator.
  """
  @spec validate_sink(map()) :: {:ok, sink_config()} | {:error, [binary()]}
  def validate_sink(%{type: :s3} = attrs), do: validate_s3_sink(attrs)
  def validate_sink(%{type: :postgres} = attrs), do: validate_postgres_sink(attrs)
  def validate_sink(%{type: :http} = attrs), do: validate_http_sink(attrs)
  def validate_sink(_), do: {:error, ["type must be one of :s3, :postgres, :http"]}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_required(errors, attrs, field, predicate, message) do
    value = Map.get(attrs, field)

    if is_nil(value) or not predicate.(value) do
      ["#{field}: #{message}" | errors]
    else
      errors
    end
  end

  defp check_optional(errors, attrs, field, predicate, message) do
    case Map.get(attrs, field) do
      nil -> errors
      value -> if predicate.(value), do: errors, else: ["#{field}: #{message}" | errors]
    end
  end

  defp validate_s3_sink(attrs) do
    required = [:bucket, :prefix, :region]
    missing = Enum.filter(required, &(not Map.has_key?(attrs, &1)))

    if missing == [] do
      {:ok, %{type: :s3, options: Map.take(attrs, required ++ [:acl, :content_type])}}
    else
      {:error, Enum.map(missing, &"#{&1}: required for S3 sink")}
    end
  end

  defp validate_postgres_sink(attrs) do
    errors = check_required([], attrs, :schema, &(is_atom(&1) and Code.ensure_loaded?(&1)), "must be a loaded Ecto schema module")

    if errors == [] do
      {:ok, %{type: :postgres, options: %{schema: attrs.schema, on_conflict: Map.get(attrs, :on_conflict, :nothing)}}}
    else
      {:error, errors}
    end
  end

  defp validate_http_sink(attrs) do
    errors = check_required([], attrs, :url, &is_binary/1, "must be a binary URL")

    if errors == [] do
      {:ok, %{type: :http, options: Map.take(attrs, [:url, :headers, :method])}}
    else
      {:error, errors}
    end
  end
end
```
