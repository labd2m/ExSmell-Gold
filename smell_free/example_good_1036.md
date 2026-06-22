```elixir
defmodule MyApp.Catalogue.ImportValidator do
  @moduledoc """
  Validates a product import payload before any database writes occur.
  Each field category has its own validation clause so that the set of
  rules is exhaustive and new field types can be added without touching
  existing logic. All violations are collected in a single pass so
  importers receive a complete error report rather than fix-one-at-a-time
  feedback.
  """

  @required_fields ~w(sku name price_cents category_slug)
  @max_sku_length 64
  @max_name_length 255
  @max_description_length 10_000
  @max_weight_grams 25_000

  @type row :: map()
  @type field :: String.t()
  @type violation :: %{field: field(), message: String.t()}
  @type result :: {:ok, row()} | {:error, [violation()]}

  @doc """
  Validates a single import row and returns either the coerced row on
  success or a list of per-field violations on failure.
  """
  @spec validate(row()) :: result()
  def validate(row) when is_map(row) do
    violations =
      []
      |> check_required(row)
      |> check_sku(row)
      |> check_name(row)
      |> check_price(row)
      |> check_weight(row)
      |> check_category(row)
      |> check_description(row)

    if violations == [] do
      {:ok, coerce(row)}
    else
      {:error, violations}
    end
  end

  @doc "Validates a batch and returns `{valid_rows, error_maps}`."
  @spec validate_batch([row()]) :: {[row()], [%{row: row(), violations: [violation()]}]}
  def validate_batch(rows) when is_list(rows) do
    Enum.reduce(rows, {[], []}, fn row, {ok_acc, err_acc} ->
      case validate(row) do
        {:ok, coerced} -> {[coerced | ok_acc], err_acc}
        {:error, vs} -> {ok_acc, [%{row: row, violations: vs} | err_acc]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  @spec check_required([violation()], row()) :: [violation()]
  defp check_required(vs, row) do
    Enum.reduce(@required_fields, vs, fn field, acc ->
      if Map.get(row, field) in [nil, ""],
        do: [%{field: field, message: "is required"} | acc],
        else: acc
    end)
  end

  @spec check_sku([violation()], row()) :: [violation()]
  defp check_sku(vs, %{"sku" => sku}) when is_binary(sku) do
    cond do
      String.length(sku) > @max_sku_length ->
        [%{field: "sku", message: "must be #{@max_sku_length} characters or fewer"} | vs]
      not String.match?(sku, ~r/\A[A-Za-z0-9_\-]+\z/) ->
        [%{field: "sku", message: "must contain only letters, digits, hyphens, and underscores"} | vs]
      true -> vs
    end
  end

  defp check_sku(vs, _), do: vs

  @spec check_name([violation()], row()) :: [violation()]
  defp check_name(vs, %{"name" => name}) when is_binary(name) do
    if String.length(name) > @max_name_length,
      do: [%{field: "name", message: "must be #{@max_name_length} characters or fewer"} | vs],
      else: vs
  end

  defp check_name(vs, _), do: vs

  @spec check_price([violation()], row()) :: [violation()]
  defp check_price(vs, %{"price_cents" => price}) do
    case parse_integer(price) do
      {:ok, n} when n > 0 -> vs
      {:ok, _} -> [%{field: "price_cents", message: "must be greater than zero"} | vs]
      :error -> [%{field: "price_cents", message: "must be a positive integer"} | vs]
    end
  end

  defp check_price(vs, _), do: vs

  @spec check_weight([violation()], row()) :: [violation()]
  defp check_weight(vs, %{"weight_grams" => w}) when not is_nil(w) do
    case parse_integer(w) do
      {:ok, n} when n in 1..@max_weight_grams -> vs
      {:ok, _} -> [%{field: "weight_grams", message: "must be between 1 and #{@max_weight_grams}"} | vs]
      :error -> [%{field: "weight_grams", message: "must be an integer"} | vs]
    end
  end

  defp check_weight(vs, _), do: vs

  @spec check_category([violation()], row()) :: [violation()]
  defp check_category(vs, %{"category_slug" => slug}) when is_binary(slug) do
    if String.match?(slug, ~r/\A[a-z0-9\-]+\z/),
      do: vs,
      else: [%{field: "category_slug", message: "must be a lowercase slug"} | vs]
  end

  defp check_category(vs, _), do: vs

  @spec check_description([violation()], row()) :: [violation()]
  defp check_description(vs, %{"description" => desc}) when is_binary(desc) do
    if String.length(desc) > @max_description_length,
      do: [%{field: "description", message: "must be #{@max_description_length} characters or fewer"} | vs],
      else: vs
  end

  defp check_description(vs, _), do: vs

  @spec coerce(row()) :: row()
  defp coerce(row) do
    row
    |> Map.update("price_cents", 0, &parse_integer_unsafe/1)
    |> Map.update("weight_grams", nil, fn v ->
      if v, do: parse_integer_unsafe(v), else: nil
    end)
  end

  @spec parse_integer(term()) :: {:ok, integer()} | :error
  defp parse_integer(n) when is_integer(n), do: {:ok, n}
  defp parse_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
  defp parse_integer(_), do: :error

  @spec parse_integer_unsafe(term()) :: integer()
  defp parse_integer_unsafe(n) when is_integer(n), do: n
  defp parse_integer_unsafe(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp parse_integer_unsafe(_), do: 0
end
```
