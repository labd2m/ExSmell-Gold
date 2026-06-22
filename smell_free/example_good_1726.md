```elixir
defmodule Pipeconf.Config do
  @moduledoc """
  Typed runtime configuration for data processing pipelines.

  Configurations are assembled from plain maps and validated before use.
  Each pipeline variant is described by a dedicated struct with explicit
  field types rather than ad-hoc keyword lists.
  """

  alias Pipeconf.Config.{Validator, SourceConfig, SinkConfig, TransformConfig}

  @enforce_keys [:name, :source, :sink, :transforms]
  defstruct [:name, :source, :sink, :transforms, max_concurrency: 4, timeout_ms: 30_000]

  @type t :: %__MODULE__{
          name: String.t(),
          source: SourceConfig.t(),
          sink: SinkConfig.t(),
          transforms: [TransformConfig.t()],
          max_concurrency: pos_integer(),
          timeout_ms: pos_integer()
        }

  @doc """
  Builds and validates a `Config` from a plain map.

  Returns `{:ok, config}` on success or `{:error, [String.t()]}` listing all
  validation failures.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(%{name: name, source: source_map, sink: sink_map, transforms: transform_list} = raw)
      when is_binary(name) and name != "" and is_map(source_map) and is_map(sink_map) and
             is_list(transform_list) do
    with {:ok, source} <- SourceConfig.from_map(source_map),
         {:ok, sink} <- SinkConfig.from_map(sink_map),
         {:ok, transforms} <- parse_transforms(transform_list) do
      config = %__MODULE__{
        name: name,
        source: source,
        sink: sink,
        transforms: transforms,
        max_concurrency: Map.get(raw, :max_concurrency, 4),
        timeout_ms: Map.get(raw, :timeout_ms, 30_000)
      }

      case Validator.validate(config) do
        [] -> {:ok, config}
        errors -> {:error, errors}
      end
    end
  end

  def from_map(_), do: {:error, ["config must include name, source, sink, and transforms"]}

  defp parse_transforms(transform_list) do
    {oks, errors} =
      transform_list
      |> Enum.map(&TransformConfig.from_map/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    if errors == [] do
      {:ok, Enum.map(oks, fn {:ok, t} -> t end)}
    else
      messages = Enum.map(errors, fn {:error, msg} -> msg end)
      {:error, messages}
    end
  end
end

defmodule Pipeconf.Config.SourceConfig do
  @moduledoc "Typed configuration for a pipeline data source."

  @enforce_keys [:type, :connection_string]
  defstruct [:type, :connection_string, batch_size: 100]

  @type source_type :: :postgres | :s3 | :kafka
  @type t :: %__MODULE__{
          type: source_type(),
          connection_string: String.t(),
          batch_size: pos_integer()
        }

  @valid_types [:postgres, :s3, :kafka]

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{type: type, connection_string: cs} = m)
      when is_binary(cs) and cs != "" do
    atom_type = if is_atom(type), do: type, else: String.to_existing_atom(to_string(type))

    if atom_type in @valid_types do
      {:ok, %__MODULE__{
        type: atom_type,
        connection_string: cs,
        batch_size: Map.get(m, :batch_size, 100)
      }}
    else
      {:error, "unknown source type: #{type}"}
    end
  rescue
    ArgumentError -> {:error, "unknown source type: #{type}"}
  end

  def from_map(_), do: {:error, "source requires type and connection_string"}
end

defmodule Pipeconf.Config.SinkConfig do
  @moduledoc "Typed configuration for a pipeline data sink."

  @enforce_keys [:type, :destination]
  defstruct [:type, :destination, overwrite: false]

  @type sink_type :: :s3 | :bigquery | :postgres
  @type t :: %__MODULE__{type: sink_type(), destination: String.t(), overwrite: boolean()}

  @valid_types [:s3, :bigquery, :postgres]

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{type: type, destination: dest} = m)
      when is_binary(dest) and dest != "" do
    atom_type = if is_atom(type), do: type, else: String.to_existing_atom(to_string(type))

    if atom_type in @valid_types do
      {:ok, %__MODULE__{type: atom_type, destination: dest, overwrite: Map.get(m, :overwrite, false)}}
    else
      {:error, "unknown sink type: #{type}"}
    end
  rescue
    ArgumentError -> {:error, "unknown sink type: #{type}"}
  end

  def from_map(_), do: {:error, "sink requires type and destination"}
end

defmodule Pipeconf.Config.TransformConfig do
  @moduledoc "Typed configuration for a single pipeline transform step."

  @enforce_keys [:name, :module]
  defstruct [:name, :module, options: %{}]

  @type t :: %__MODULE__{name: String.t(), module: module(), options: map()}

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{name: name, module: mod} = m) when is_binary(name) and is_atom(mod) do
    {:ok, %__MODULE__{name: name, module: mod, options: Map.get(m, :options, %{})}}
  end

  def from_map(_), do: {:error, "transform requires name and module"}
end

defmodule Pipeconf.Config.Validator do
  @moduledoc false

  alias Pipeconf.Config

  @spec validate(Config.t()) :: [String.t()]
  def validate(%Config{max_concurrency: c, timeout_ms: t, transforms: transforms}) do
    []
    |> check(is_integer(c) and c > 0, "max_concurrency must be a positive integer")
    |> check(is_integer(t) and t > 0, "timeout_ms must be a positive integer")
    |> check(transforms != [], "at least one transform is required")
  end

  defp check(errors, true, _msg), do: errors
  defp check(errors, false, msg), do: [msg | errors]
end
```
