**File:** `example_good_1174.md`

```elixir
defmodule MediaPipeline.Asset do
  @moduledoc "Represents an uploaded media asset awaiting processing."

  @enforce_keys [:id, :original_path, :content_type, :size_bytes]
  defstruct [:id, :original_path, :content_type, :size_bytes, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          original_path: String.t(),
          content_type: String.t(),
          size_bytes: pos_integer(),
          metadata: map() | nil
        }
end

defmodule MediaPipeline.ProcessingResult do
  @moduledoc "Holds the output of a completed media processing pipeline run."

  @enforce_keys [:asset_id, :outputs, :duration_ms]
  defstruct [:asset_id, :outputs, :duration_ms, :warnings]

  @type output :: %{format: String.t(), path: String.t(), size_bytes: pos_integer()}
  @type t :: %__MODULE__{
          asset_id: String.t(),
          outputs: [output()],
          duration_ms: non_neg_integer(),
          warnings: [String.t()]
        }
end

defmodule MediaPipeline.Stage do
  @moduledoc "Behaviour for individual stages in the media processing pipeline."

  alias MediaPipeline.Asset

  @doc "Processes the asset and returns an updated asset or an error."
  @callback process(Asset.t(), keyword()) :: {:ok, Asset.t()} | {:error, term()}

  @doc "Returns a human-readable name for this stage."
  @callback stage_name() :: String.t()
end

defmodule MediaPipeline.Stages.Validate do
  @moduledoc "Validates an asset's content type and size before further processing."

  @behaviour MediaPipeline.Stage

  alias MediaPipeline.Asset

  @max_size_bytes 500 * 1024 * 1024
  @allowed_types ~w(image/jpeg image/png image/webp video/mp4 video/webm)

  @impl MediaPipeline.Stage
  def stage_name, do: "validate"

  @impl MediaPipeline.Stage
  def process(%Asset{} = asset, _opts) do
    with :ok <- check_content_type(asset.content_type),
         :ok <- check_file_size(asset.size_bytes) do
      {:ok, asset}
    end
  end

  defp check_content_type(type) when type in @allowed_types, do: :ok
  defp check_content_type(type), do: {:error, {:unsupported_content_type, type}}

  defp check_file_size(size) when size <= @max_size_bytes, do: :ok
  defp check_file_size(size), do: {:error, {:file_too_large, size, @max_size_bytes}}
end

defmodule MediaPipeline.Stages.ExtractMetadata do
  @moduledoc "Extracts technical metadata from the raw asset file."

  @behaviour MediaPipeline.Stage

  alias MediaPipeline.Asset

  @impl MediaPipeline.Stage
  def stage_name, do: "extract_metadata"

  @impl MediaPipeline.Stage
  def process(%Asset{original_path: path} = asset, _opts) do
    case read_metadata(path) do
      {:ok, metadata} -> {:ok, %{asset | metadata: metadata}}
      {:error, reason} -> {:error, {:metadata_extraction_failed, reason}}
    end
  end

  defp read_metadata(_path) do
    {:ok, %{width: 1920, height: 1080, duration_seconds: nil, color_space: "sRGB"}}
  end
end

defmodule MediaPipeline.Stages.Transcode do
  @moduledoc "Transcodes the asset into one or more target formats."

  @behaviour MediaPipeline.Stage

  alias MediaPipeline.Asset

  @impl MediaPipeline.Stage
  def stage_name, do: "transcode"

  @impl MediaPipeline.Stage
  def process(%Asset{} = asset, opts) do
    target_formats = Keyword.get(opts, :formats, ["webp"])
    output_dir = Keyword.get(opts, :output_dir, "/tmp/outputs")

    results =
      Enum.map(target_formats, fn format ->
        output_path = Path.join(output_dir, "#{asset.id}.#{format}")
        transcode_to(asset.original_path, output_path, format)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, asset}
    else
      {:error, {:transcode_errors, Enum.map(errors, fn {:error, r} -> r end)}}
    end
  end

  defp transcode_to(_src, _dst, _format), do: :ok
end

defmodule MediaPipeline.Runner do
  @moduledoc """
  Executes a configured sequence of processing stages against an asset,
  collecting timing and warnings along the way.
  """

  alias MediaPipeline.{Asset, ProcessingResult}

  @type stage_spec :: {module(), keyword()}

  @spec run(Asset.t(), [stage_spec()]) ::
          {:ok, ProcessingResult.t()} | {:error, {String.t(), term()}}
  def run(%Asset{} = asset, stages) when is_list(stages) do
    started_at = System.monotonic_time(:millisecond)

    case execute_stages(asset, stages, []) do
      {:ok, _final_asset, warnings} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at
        result = %ProcessingResult{
          asset_id: asset.id,
          outputs: [],
          duration_ms: duration_ms,
          warnings: warnings
        }
        {:ok, result}

      {:error, stage_name, reason} ->
        {:error, {stage_name, reason}}
    end
  end

  defp execute_stages(asset, [], warnings), do: {:ok, asset, warnings}

  defp execute_stages(asset, [{stage_mod, opts} | rest], warnings) do
    case stage_mod.process(asset, opts) do
      {:ok, updated_asset} ->
        execute_stages(updated_asset, rest, warnings)

      {:error, reason} ->
        {:error, stage_mod.stage_name(), reason}
    end
  end
end
```
