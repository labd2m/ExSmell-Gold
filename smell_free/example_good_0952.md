```elixir
defmodule Catalog.BreadcrumbBuilder do
  @moduledoc """
  Constructs navigation breadcrumb trails from a category tree and a
  target slug. Breadcrumbs are path segments from the root to the current
  node, enabling users to navigate back up the hierarchy. The builder
  traverses a pre-loaded tree struct so no database call is needed at
  render time. All functions are pure.
  """

  alias Catalog.CategoryTree

  @type breadcrumb :: %{label: String.t(), slug: String.t(), url: String.t()}
  @type build_result :: {:ok, [breadcrumb()]} | {:error, :not_found}

  @doc """
  Builds the breadcrumb trail for `slug` within `tree`. Returns breadcrumbs
  in root-first order, each with a label, slug, and path URL.
  """
  @spec build([CategoryTree.t()], String.t()) :: build_result()
  def build(tree, slug) when is_list(tree) and is_binary(slug) do
    case CategoryTree.ancestors(tree, find_id(tree, slug)) do
      [] ->
        case CategoryTree.find_by_slug(tree, slug) do
          {:ok, node} -> {:ok, [to_breadcrumb(node)]}
          {:error, :not_found} -> {:error, :not_found}
        end

      ancestors ->
        case CategoryTree.find_by_slug(tree, slug) do
          {:ok, current} ->
            crumbs = Enum.map(ancestors, &to_breadcrumb/1) ++ [to_breadcrumb(current)]
            {:ok, crumbs}

          {:error, :not_found} ->
            {:error, :not_found}
        end
    end
  end

  @doc "Returns a root-only breadcrumb list for the top-level `slug`."
  @spec root_crumb(String.t(), String.t()) :: [breadcrumb()]
  def root_crumb(label, slug) when is_binary(label) and is_binary(slug) do
    [%{label: label, slug: slug, url: path_for(slug)}]
  end

  @doc "Prepends a home breadcrumb to an existing trail."
  @spec prepend_home([breadcrumb()]) :: [breadcrumb()]
  def prepend_home(breadcrumbs) when is_list(breadcrumbs) do
    home = %{label: "Home", slug: "", url: "/"}
    [home | breadcrumbs]
  end

  @doc "Serialises a breadcrumb list to JSON-LD structured data for SEO."
  @spec to_json_ld([breadcrumb()]) :: map()
  def to_json_ld(breadcrumbs) when is_list(breadcrumbs) do
    items =
      breadcrumbs
      |> Enum.with_index(1)
      |> Enum.map(fn {crumb, pos} ->
        %{
          "@type" => "ListItem",
          "position" => pos,
          "name" => crumb.label,
          "item" => crumb.url
        }
      end)

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => items
    }
  end

  defp find_id(tree, slug) do
    case CategoryTree.find_by_slug(tree, slug) do
      {:ok, node} -> node.id
      {:error, :not_found} -> nil
    end
  end

  defp to_breadcrumb(%CategoryTree{} = node) do
    %{label: node.name, slug: node.slug, url: path_for(node.slug)}
  end

  defp path_for(""), do: "/"
  defp path_for(slug), do: "/categories/#{slug}"
end
```
