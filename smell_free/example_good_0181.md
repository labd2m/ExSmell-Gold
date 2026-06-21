```elixir
defmodule AppWeb.JsonApi.Serializer do
  @moduledoc """
  Serializes domain structs into JSON:API-compliant response envelopes.

  Callers provide a resource type atom and an attribute-mapping function.
  Relationship data and meta sections are composed via the options list,
  keeping serialization logic out of controller actions.
  """

  @type resource_type :: String.t()
  @type attrs_fn :: (struct() -> map())
  @type document :: map()

  @doc """
  Serializes a single resource into a JSON:API document.
  """
  @spec one(struct(), resource_type(), attrs_fn(), keyword()) :: document()
  def one(resource, type, attrs_fn, opts \\ []) when is_binary(type) and is_function(attrs_fn, 1) do
    %{
      data: resource_object(resource, type, attrs_fn, opts),
      meta: build_meta(opts)
    }
  end

  @doc """
  Serializes a list of resources into a JSON:API document with pagination meta.
  """
  @spec many([struct()], resource_type(), attrs_fn(), keyword()) :: document()
  def many(resources, type, attrs_fn, opts \\ []) when is_list(resources) and is_binary(type) do
    %{
      data: Enum.map(resources, &resource_object(&1, type, attrs_fn, opts)),
      meta: build_meta(opts)
    }
  end

  @doc """
  Builds a JSON:API error document from a list of error maps.
  """
  @spec errors([map()]) :: map()
  def errors(error_list) when is_list(error_list) do
    %{errors: Enum.map(error_list, &normalize_error/1)}
  end

  @doc """
  Builds a JSON:API error document from an Ecto changeset.
  """
  @spec from_changeset(Ecto.Changeset.t()) :: map()
  def from_changeset(%Ecto.Changeset{} = changeset) do
    error_list =
      changeset
      |> Ecto.Changeset.traverse_errors(&translate_error/1)
      |> Enum.flat_map(&changeset_errors_to_json_api/1)

    errors(error_list)
  end

  defp resource_object(resource, type, attrs_fn, opts) do
    base = %{
      id: to_string(resource.id),
      type: type,
      attributes: attrs_fn.(resource)
    }

    base
    |> maybe_put(:relationships, build_relationships(resource, opts))
    |> maybe_put(:links, build_links(resource, type, opts))
  end

  defp build_relationships(resource, opts) do
    case Keyword.get(opts, :relationships) do
      nil -> nil
      rel_fn when is_function(rel_fn, 1) -> rel_fn.(resource)
    end
  end

  defp build_links(resource, type, opts) do
    case Keyword.get(opts, :base_url) do
      nil -> nil
      base_url -> %{self: "#{base_url}/#{type}/#{resource.id}"}
    end
  end

  defp build_meta(opts) do
    base = %{api_version: "1.0"}
    pagination = Keyword.get(opts, :pagination, %{})
    Map.merge(base, pagination)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_error(%{title: _, detail: _} = err), do: err
  defp normalize_error(%{message: msg}), do: %{title: "Error", detail: msg}
  defp normalize_error(err) when is_binary(err), do: %{title: "Error", detail: err}

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp changeset_errors_to_json_api({field, messages}) do
    Enum.map(messages, fn msg ->
      %{title: "Validation error", detail: msg, source: %{pointer: "/data/attributes/#{field}"}}
    end)
  end
end
```
