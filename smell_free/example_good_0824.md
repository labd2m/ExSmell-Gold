```elixir
defmodule MapSanitizer do
  @moduledoc """
  Recursively cleans nested maps and lists by removing blank values,
  normalising key types, and applying custom field-level transformations.

  All operations are composable via option flags rather than requiring
  callers to chain multiple passes. The sanitizer never mutates input;
  every function returns a new value.
  """

  @type opts :: [
          compact: boolean(),
          normalize_keys: :atoms | :strings | false,
          atom_allowlist: [atom()],
          trim_strings: boolean(),
          drop_keys: [term()]
        ]

  @spec sanitize(term(), opts()) :: term()
  def sanitize(value, opts \\ []) do
    compact = Keyword.get(opts, :compact, true)
    key_mode = Keyword.get(opts, :normalize_keys, false)
    atom_allowlist = Keyword.get(opts, :atom_allowlist, [])
    trim = Keyword.get(opts, :trim_strings, true)
    drop_keys = Keyword.get(opts, :drop_keys, [])

    config = %{
      compact: compact,
      key_mode: key_mode,
      atom_allowlist: atom_allowlist,
      trim: trim,
      drop_keys: drop_keys
    }

    do_sanitize(value, config)
  end

  @spec compact(map() | list()) :: map() | list()
  def compact(value), do: sanitize(value, compact: true, normalize_keys: false, trim_strings: false)

  @spec stringify_keys(map()) :: map()
  def stringify_keys(map), do: sanitize(map, normalize_keys: :strings, compact: false, trim_strings: false)

  @spec atomize_keys(map(), [atom()]) :: map()
  def atomize_keys(map, allowlist), do: sanitize(map, normalize_keys: :atoms, atom_allowlist: allowlist, compact: false, trim_strings: false)

  defp do_sanitize(map, config) when is_map(map) do
    map
    |> Enum.reject(fn {k, _} -> k in config.drop_keys end)
    |> Enum.flat_map(fn {k, v} ->
      new_key = normalize_key(k, config)
      new_val = do_sanitize(v, config)

      if config.compact and blank?(new_val) do
        []
      else
        [{new_key, new_val}]
      end
    end)
    |> Map.new()
  end

  defp do_sanitize(list, config) when is_list(list) do
    list
    |> Enum.map(&do_sanitize(&1, config))
    |> then(fn items ->
      if config.compact, do: Enum.reject(items, &blank?/1), else: items
    end)
  end

  defp do_sanitize(str, %{trim: true}) when is_binary(str), do: String.trim(str)
  defp do_sanitize(value, _config), do: value

  defp normalize_key(key, %{key_mode: :strings}) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key, %{key_mode: :strings}), do: to_string(key)

  defp normalize_key(key, %{key_mode: :atoms, atom_allowlist: allowlist}) when is_binary(key) do
    Enum.find(allowlist, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(key, _config), do: key

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(map) when is_map(map), do: map_size(map) == 0
  defp blank?(list) when is_list(list), do: list == []
  defp blank?(_), do: false
end
```
