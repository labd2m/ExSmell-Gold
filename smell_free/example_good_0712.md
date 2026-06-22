```elixir
defmodule AppWeb.Plugs.KeyNormalizer do
  @moduledoc """
  A Plug that recursively converts request body parameter keys between
  naming conventions so that Phoenix controllers always receive snake_case
  regardless of the client's serialization preference.

  Configurable per-mount with `:from` and `:to` strategy options.
  Applies only to parsed body params; query params are left unchanged.
  """

  import Plug.Conn

  @behaviour Plug

  @type strategy :: :camel_to_snake | :snake_to_camel | :pascal_to_snake

  @impl Plug
  def init(opts) do
    %{
      from: Keyword.get(opts, :from, :camel_to_snake),
      exclude: Keyword.get(opts, :exclude, [])
    }
  end

  @impl Plug
  def call(conn, %{from: strategy, exclude: exclude}) do
    conn = fetch_body_params(conn)

    normalized =
      conn.body_params
      |> normalize_map(strategy, exclude)

    %{conn | body_params: normalized, params: Map.merge(conn.params, normalized)}
  end

  defp fetch_body_params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> Plug.Conn.fetch_query_params(conn)
      _ -> conn
    end
  end

  defp normalize_map(params, strategy, exclude) when is_map(params) do
    Map.new(params, fn {key, value} ->
      normalized_key = if key in exclude, do: key, else: normalize_key(key, strategy)
      {normalized_key, normalize_value(value, strategy, exclude)}
    end)
  end

  defp normalize_map(other, _strategy, _exclude), do: other

  defp normalize_value(value, strategy, exclude) when is_map(value) do
    normalize_map(value, strategy, exclude)
  end

  defp normalize_value(values, strategy, exclude) when is_list(values) do
    Enum.map(values, &normalize_value(&1, strategy, exclude))
  end

  defp normalize_value(value, _strategy, _exclude), do: value

  defp normalize_key(key, :camel_to_snake) when is_binary(key) do
    key
    |> String.replace(~r/([A-Z])/, "_\\1")
    |> String.downcase()
    |> String.trim_leading("_")
  end

  defp normalize_key(key, :pascal_to_snake) when is_binary(key) do
    key
    |> String.replace(~r/([A-Z])/, "_\\1")
    |> String.downcase()
    |> String.trim_leading("_")
  end

  defp normalize_key(key, :snake_to_camel) when is_binary(key) do
    parts = String.split(key, "_")

    case parts do
      [] -> key
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
    end
  end

  defp normalize_key(key, _strategy), do: key
end
```
