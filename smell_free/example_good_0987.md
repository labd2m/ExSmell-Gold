```elixir
defmodule Config.DeepMerge do
  @moduledoc """
  Provides schema-aware deep merging of nested configuration maps.
  Scalar values are replaced; lists and maps are merged recursively
  using a configurable merge strategy per key. An optional schema
  declaration constrains which keys are permitted and what types they
  accept, surfacing mismatches before the configuration is applied.
  All operations are pure: no I/O, no process state.
  """

  @type merge_strategy :: :replace | :concat | :deep_merge
  @type schema_entry :: %{
          optional(:type) => :string | :integer | :boolean | :list | :map,
          optional(:required) => boolean(),
          optional(:strategy) => merge_strategy(),
          optional(:keys) => %{atom() => schema_entry()}
        }

  @doc """
  Deep-merges `override` into `base`, applying per-key strategies from
  `schema`. Returns `{:ok, merged}` or `{:error, [validation_error]}`.
  When no schema is provided, all keys are merged using `:deep_merge`.
  """
  @spec merge(map(), map(), %{atom() => schema_entry()}) ::
          {:ok, map()} | {:error, [binary()]}
  def merge(base, override, schema \\ %{})
      when is_map(base) and is_map(override) and is_map(schema) do
    errors = validate(override, schema, [])

    if errors == [] do
      merged = do_merge(base, override, schema)
      {:ok, merged}
    else
      {:error, errors}
    end
  end

  @doc """
  Deep-merges without schema validation. Returns the merged map directly.
  """
  @spec merge!(map(), map()) :: map()
  def merge!(base, override) when is_map(base) and is_map(override) do
    do_merge(base, override, %{})
  end

  @doc """
  Merges a list of maps left to right, each overriding the previous.
  Equivalent to `Enum.reduce(maps, %{}, &merge!(&2, &1))`.
  """
  @spec merge_all([map()]) :: map()
  def merge_all(maps) when is_list(maps) do
    Enum.reduce(maps, %{}, &merge!(&2, &1))
  end

  # ---------------------------------------------------------------------------
  # Private merge logic
  # ---------------------------------------------------------------------------

  defp do_merge(base, override, schema) do
    all_keys = MapSet.union(MapSet.new(Map.keys(base)), MapSet.new(Map.keys(override)))

    Enum.reduce(all_keys, %{}, fn key, acc ->
      base_val = Map.get(base, key)
      override_val = Map.get(override, key)
      key_schema = Map.get(schema, key, %{})
      strategy = Map.get(key_schema, :strategy, :deep_merge)

      merged_val = merge_values(base_val, override_val, strategy, Map.get(key_schema, :keys, %{}))
      Map.put(acc, key, merged_val)
    end)
  end

  defp merge_values(nil, override, _strategy, _sub_schema), do: override
  defp merge_values(base, nil, _strategy, _sub_schema), do: base

  defp merge_values(base, override, :replace, _sub_schema), do: override

  defp merge_values(base, override, :concat, _sub_schema)
       when is_list(base) and is_list(override) do
    base ++ override
  end

  defp merge_values(base, override, _strategy, sub_schema)
       when is_map(base) and is_map(override) do
    do_merge(base, override, sub_schema)
  end

  defp merge_values(_base, override, _strategy, _sub_schema), do: override

  # ---------------------------------------------------------------------------
  # Schema validation
  # ---------------------------------------------------------------------------

  defp validate(map, schema, path) when is_map(map) do
    required_errors = check_required(map, schema, path)
    type_errors = check_types(map, schema, path)
    nested_errors = check_nested(map, schema, path)

    required_errors ++ type_errors ++ nested_errors
  end

  defp check_required(map, schema, path) do
    schema
    |> Enum.filter(fn {_k, spec} -> Map.get(spec, :required, false) end)
    |> Enum.flat_map(fn {key, _spec} ->
      if Map.has_key?(map, key) do
        []
      else
        [path_msg(path, key, "is required but missing")]
      end
    end)
  end

  defp check_types(map, schema, path) do
    Enum.flat_map(schema, fn {key, spec} ->
      case {Map.get(map, key), Map.get(spec, :type)} do
        {nil, _} -> []
        {_, nil} -> []
        {val, :string} when not is_binary(val) -> [path_msg(path, key, "must be a string")]
        {val, :integer} when not is_integer(val) -> [path_msg(path, key, "must be an integer")]
        {val, :boolean} when not is_boolean(val) -> [path_msg(path, key, "must be a boolean")]
        {val, :list} when not is_list(val) -> [path_msg(path, key, "must be a list")]
        {val, :map} when not is_map(val) -> [path_msg(path, key, "must be a map")]
        _ -> []
      end
    end)
  end

  defp check_nested(map, schema, path) do
    Enum.flat_map(schema, fn {key, spec} ->
      case {Map.get(map, key), Map.get(spec, :keys)} do
        {val, sub_schema} when is_map(val) and is_map(sub_schema) ->
          validate(val, sub_schema, path ++ [key])

        _ ->
          []
      end
    end)
  end

  defp path_msg([], key, msg), do: "#{key}: #{msg}"
  defp path_msg(path, key, msg), do: "#{Enum.join(path, ".")}.#{key}: #{msg}"
end
```
