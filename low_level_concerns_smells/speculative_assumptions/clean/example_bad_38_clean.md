```elixir
defmodule Catalog.FeedParser do
  @moduledoc """
  Parses XML product feed files provided by suppliers for catalog ingestion.
  The feed follows a simplified subset of the Google Product Data Specification.

  Expected product element structure:
    <product>
      <id>SKU123</id>
      <title>Product Name</title>
      <description>...</description>
      <price currency="BRL">99.90</price>
      <availability>in_stock</availability>
      <brand>BrandName</brand>
      <category>Electronics > Phones</category>
      <image_link>https://...</image_link>
      <gtin>7891234567890</gtin>
    </product>
  """

  require Logger

  @required_fields ~w(id title price availability)

  def parse_file(path) do
    with {:ok, content}           <- File.read(path),
         {:ok, {_, _, elements}}  <- :xmerl_scan.string(String.to_charlist(content)) |> wrap_xmerl() do
      products =
        elements
        |> find_elements(:product)
        |> Enum.map(&extract_product/1)
        |> Enum.reject(&is_nil/1)

      {:ok, products}
    end
  end

  defp extract_product({:product, _attrs, children}) do
    %{
      id:           text_of(children, :id),
      title:        text_of(children, :title),
      description:  text_of(children, :description),
      price:        children |> text_of(:price) |> parse_price(),
      currency:     attr_of(children, :price, "currency"),
      availability: text_of(children, :availability),
      brand:        text_of(children, :brand),
      category:     text_of(children, :category),
      image_link:   text_of(children, :image_link),
      gtin:         text_of(children, :gtin)
    }
  end

  defp extract_product(_), do: nil

  defp text_of(children, tag) do
    children
    |> Enum.find(fn {t, _, _} -> t == tag end)
    |> then(fn {_, _, content} -> List.first(content) end)
    |> to_string()
  rescue
    _ -> nil
  end

  defp attr_of(children, tag, attr_name) do
    case Enum.find(children, fn {t, _, _} -> t == tag end) do
      {_, attrs, _} -> Keyword.get(attrs, String.to_atom(attr_name))
      nil           -> nil
    end
  rescue
    _ -> nil
  end

  defp find_elements({_, _, children}, tag) do
    Enum.filter(children, fn
      {^tag, _, _} -> true
      _            -> false
    end)
  end

  defp find_elements(_, _), do: []

  defp wrap_xmerl({doc, _rest}), do: {:ok, doc}
  defp wrap_xmerl({:error, _} = e), do: e
  defp wrap_xmerl(_), do: {:error, :xmerl_failed}

  defp parse_price(nil), do: nil
  defp parse_price(str) do
    case Float.parse(String.trim(str)) do
      {f, _} -> f
      :error -> nil
    end
  end

  def validate_product(product) do
    missing = Enum.reject(@required_fields, fn f -> not is_nil(Map.get(product, String.to_atom(f))) end)

    if missing == [] do
      {:ok, product}
    else
      {:error, {:missing_fields, missing}}
    end
  end

  def in_stock?(%{availability: "in_stock"}), do: true
  def in_stock?(_), do: false

  def describe(%{id: id, title: title, price: price, currency: currency}) do
    "#{id}: #{title} — #{currency} #{price}"
  end

  def describe(_), do: "Unknown product"
end
```
