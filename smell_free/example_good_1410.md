```elixir
defmodule Pipeline.Transform.CsvNormalizer do
  @moduledoc """
  Transforms raw CSV row maps into normalized domain structs.
  Each row is independently validated; invalid rows are collected separately
  from successful ones so callers can handle partial failures explicitly.
  """

  @type raw_row :: %{String.t() => String.t()}
  @type normalized_row :: %{
          id: String.t(),
          email: String.t(),
          age: non_neg_integer(),
          country_code: String.t()
        }
  @type result :: %{ok: [normalized_row()], errors: [{non_neg_integer(), String.t()}]}

  @doc """
  Processes a list of raw CSV row maps and returns a result map with
  successful rows under `:ok` and indexed errors under `:errors`.
  """
  @spec process([raw_row()]) :: result()
  def process(rows) when is_list(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce(%{ok: [], errors: []}, &accumulate_row/2)
    |> finalize()
  end

  defp accumulate_row({row, index}, acc) do
    case normalize_row(row) do
      {:ok, normalized} -> %{acc | ok: [normalized | acc.ok]}
      {:error, reason} -> %{acc | errors: [{index, reason} | acc.errors]}
    end
  end

  defp finalize(acc) do
    %{ok: Enum.reverse(acc.ok), errors: Enum.reverse(acc.errors)}
  end

  defp normalize_row(row) when is_map(row) do
    with {:ok, id} <- extract_nonempty_string(row, "id"),
         {:ok, email} <- extract_email(row),
         {:ok, age} <- extract_age(row),
         {:ok, country_code} <- extract_country_code(row) do
      {:ok, %{id: id, email: email, age: age, country_code: country_code}}
    end
  end

  defp extract_nonempty_string(row, key) do
    case Map.fetch(row, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, String.trim(val)}
      {:ok, _} -> {:error, "field '#{key}' must be a non-empty string"}
      :error -> {:error, "field '#{key}' is missing"}
    end
  end

  defp extract_email(row) do
    with {:ok, raw} <- extract_nonempty_string(row, "email") do
      trimmed = String.downcase(String.trim(raw))

      if String.match?(trimmed, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
        {:ok, trimmed}
      else
        {:error, "field 'email' is not a valid email address"}
      end
    end
  end

  defp extract_age(row) do
    with {:ok, raw} <- extract_nonempty_string(row, "age") do
      case Integer.parse(String.trim(raw)) do
        {age, ""} when age >= 0 -> {:ok, age}
        _ -> {:error, "field 'age' must be a non-negative integer"}
      end
    end
  end

  defp extract_country_code(row) do
    with {:ok, raw} <- extract_nonempty_string(row, "country_code") do
      code = String.upcase(String.trim(raw))

      if String.match?(code, ~r/^[A-Z]{2}$/) do
        {:ok, code}
      else
        {:error, "field 'country_code' must be a 2-letter ISO code"}
      end
    end
  end
end
```
