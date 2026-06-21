# File: `example_good_239.md`

```elixir
defmodule DataImport.SchemaMapper do
  @moduledoc """
  Transforms raw import records into a canonical schema by applying a
  declarative field mapping.

  A mapping specifies source field names, target field names, optional
  transformations, and required/optional status. The mapper is pure:
  it never writes to a database; callers pipe its output into their
  own persistence layer.
  """

  @type source_key :: String.t() | atom()
  @type target_key :: atom()
  @type transform_fn :: (term() -> {:ok, term()} | {:error, String.t()})

  @type field_mapping :: %{
          required(:from) => source_key(),
          required(:to) => target_key(),
          optional(:required) => boolean(),
          optional(:default) => term(),
          optional(:transform) => transform_fn()
        }

  @type map_result ::
          {:ok, map()}
          | {:error, [{target_key(), String.t()}]}

  @doc """
  Maps `source` through `mappings`, returning a canonical record.

  Each mapping extracts the `:from` key from `source`, applies an
  optional `:transform`, and writes the result under `:to` in the
  output map. If a required field is absent and no default is given,
  the field is collected as an error. All errors are returned together.
  """
  @spec map(map(), [field_mapping()]) :: map_result()
  def map(source, mappings) when is_map(source) and is_list(mappings) do
    {output, errors} =
      Enum.reduce(mappings, {%{}, []}, fn mapping, {out, errs} ->
        apply_mapping(source, mapping, out, errs)
      end)

    case errors do
      [] -> {:ok, output}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Maps a list of source records, returning `{successes, failures}`.

  Each element of `failures` includes the original record and the
  list of field errors, enabling partial-success import workflows.
  """
  @spec map_all([map()], [field_mapping()]) ::
          {[map()], [%{record: map(), errors: [{target_key(), String.t()}]}]}
  def map_all(sources, mappings) when is_list(sources) and is_list(mappings) do
    {successes, failures} =
      Enum.reduce(sources, {[], []}, fn source, {ok_acc, err_acc} ->
        case map(source, mappings) do
          {:ok, record} -> {[record | ok_acc], err_acc}
          {:error, errors} -> {ok_acc, [%{record: source, errors: errors} | err_acc]}
        end
      end)

    {Enum.reverse(successes), Enum.reverse(failures)}
  end

  @doc """
  Builds a transform function that applies a sequence of transforms in order,
  short-circuiting on the first error.
  """
  @spec compose_transforms([transform_fn()]) :: transform_fn()
  def compose_transforms(transforms) when is_list(transforms) do
    fn value ->
      Enum.reduce_while(transforms, {:ok, value}, fn transform, {:ok, current} ->
        case transform.(current) do
          {:ok, _} = ok -> {:cont, ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Built-in transform: trims a string value and returns an error for empty strings.
  """
  @spec trim_required(term()) :: {:ok, String.t()} | {:error, String.t()}
  def trim_required(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, "must not be blank"}, else: {:ok, trimmed}
  end

  def trim_required(value), do: {:ok, value}

  @doc """
  Built-in transform: converts a value to a downcased string.
  """
  @spec downcase(term()) :: {:ok, String.t()}
  def downcase(value), do: {:ok, value |> to_string() |> String.downcase()}

  defp apply_mapping(source, mapping, output, errors) do
    raw = fetch_source_value(source, mapping.from)
    required = Map.get(mapping, :required, true)
    default = Map.get(mapping, :default, :__no_default__)

    cond do
      raw == nil and required and default == :__no_default__ ->
        error = {mapping.to, "field '#{mapping.from}' is required but missing"}
        {output, [error | errors]}

      raw == nil ->
        value = if default == :__no_default__, do: nil, else: default
        {Map.put(output, mapping.to, value), errors}

      true ->
        apply_transform(output, errors, mapping, raw)
    end
  end

  defp apply_transform(output, errors, mapping, raw) do
    case Map.get(mapping, :transform) do
      nil ->
        {Map.put(output, mapping.to, raw), errors}

      transform_fn ->
        case transform_fn.(raw) do
          {:ok, value} -> {Map.put(output, mapping.to, value), errors}
          {:error, msg} -> {output, [{mapping.to, msg} | errors]}
        end
    end
  end

  defp fetch_source_value(source, key) when is_atom(key) do
    Map.get(source, key) || Map.get(source, Atom.to_string(key))
  end

  defp fetch_source_value(source, key) when is_binary(key) do
    Map.get(source, key) ||
      case Integer.parse(key) do
        :error -> Map.get(source, String.to_existing_atom(key))
        _ -> nil
      end
  rescue
    ArgumentError -> Map.get(source, key)
  end
end
```
