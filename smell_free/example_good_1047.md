```elixir
defmodule Telemetry.Metrics.Exporter do
  @moduledoc """
  Exports collected telemetry metrics to a remote observability backend.
  Configuration is accepted per-call via options, allowing the same
  exporter to target different backends in tests and production.
  """

  alias Telemetry.Metrics.{Batch, ExportResult, HttpClient}

  @type export_opts :: [
          endpoint: String.t(),
          api_key: String.t(),
          timeout_ms: pos_integer(),
          compress: boolean()
        ]

  @doc """
  Exports a batch of metrics. Returns `{:ok, ExportResult.t()}` on success.

  Required options: `:endpoint`, `:api_key`.
  Optional options: `:timeout_ms` (default 5000), `:compress` (default false).
  """
  @spec export(Batch.t(), export_opts()) ::
          {:ok, ExportResult.t()} | {:error, :auth_failure | :server_error | :timeout}
  def export(%Batch{} = batch, opts) do
    with {:ok, endpoint} <- fetch_required(opts, :endpoint),
         {:ok, api_key} <- fetch_required(opts, :api_key),
         {:ok, body} <- serialize(batch, Keyword.get(opts, :compress, false)),
         {:ok, response} <- send_request(endpoint, api_key, body, opts) do
      parse_response(response)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec fetch_required(keyword(), atom()) :: {:ok, term()} | {:error, atom()}
  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _} -> {:error, :"invalid_#{key}"}
      :error -> {:error, :"missing_#{key}"}
    end
  end

  @spec serialize(Batch.t(), boolean()) :: {:ok, binary()} | {:error, :serialization_failed}
  defp serialize(%Batch{metrics: metrics}, compress) do
    case Jason.encode(%{metrics: metrics, exported_at: DateTime.utc_now()}) do
      {:ok, json} -> maybe_compress(json, compress)
      {:error, _} -> {:error, :serialization_failed}
    end
  end

  @spec maybe_compress(String.t(), boolean()) :: {:ok, binary()}
  defp maybe_compress(data, false), do: {:ok, data}

  defp maybe_compress(data, true) do
    {:ok, :zlib.compress(data)}
  end

  @spec send_request(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, :timeout}
  defp send_request(endpoint, api_key, body, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    headers = [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]

    case HttpClient.post(endpoint, body, headers, timeout: timeout) do
      {:ok, response} -> {:ok, response}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _} -> {:error, :server_error}
    end
  end

  @spec parse_response(map()) ::
          {:ok, ExportResult.t()} | {:error, :auth_failure | :server_error}
  defp parse_response(%{status: 200, body: body}) do
    {:ok, %ExportResult{accepted: body["accepted"] || 0, rejected: body["rejected"] || 0}}
  end

  defp parse_response(%{status: 401}), do: {:error, :auth_failure}
  defp parse_response(%{status: 403}), do: {:error, :auth_failure}
  defp parse_response(_), do: {:error, :server_error}
end

defmodule Telemetry.Metrics.Batch do
  @moduledoc "Represents a batch of telemetry metrics ready for export."

  @enforce_keys [:metrics]
  defstruct [:metrics, :collected_at]

  @type t :: %__MODULE__{
          metrics: [map()],
          collected_at: DateTime.t() | nil
        }
end

defmodule Telemetry.Metrics.ExportResult do
  @moduledoc "Captures the result of a metrics export operation."

  defstruct [:accepted, :rejected]

  @type t :: %__MODULE__{
          accepted: non_neg_integer(),
          rejected: non_neg_integer()
        }
end
```
