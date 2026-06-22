```elixir
defmodule Realestate.Valuations.ComparableSelector do
  @moduledoc """
  Selects comparable property sales for use in automated valuation models.
  Comparables are ranked by similarity score across configurable property attributes.
  All scoring weights are validated and normalised before selection.
  """

  @type property :: %{
          id: String.t(),
          postcode: String.t(),
          bedrooms: non_neg_integer(),
          floor_area_sqm: float(),
          sale_price_cents: pos_integer(),
          sold_on: Date.t(),
          property_type: :house | :apartment | :townhouse
        }

  @type weight_config :: %{
          postcode: float(),
          bedrooms: float(),
          floor_area: float(),
          recency: float(),
          property_type: float()
        }

  @type scored :: %{property: property(), score: float()}

  @default_weights %{
    postcode: 0.35,
    bedrooms: 0.20,
    floor_area: 0.25,
    recency: 0.10,
    property_type: 0.10
  }

  @doc """
  Selects the top `n` comparables from `candidates` most similar to `subject`.

  ## Options
    - `:weights` - custom `weight_config` map (default: built-in weights)
    - `:max_age_days` - exclude sales older than this many days (default: 365)
  """
  @spec select([property()], property(), pos_integer(), keyword()) ::
          {:ok, [scored()]} | {:error, String.t()}
  def select(candidates, subject, n, opts \\ [])
      when is_list(candidates) and is_map(subject) and is_integer(n) and n > 0 do
    weights = Keyword.get(opts, :weights, @default_weights)
    max_age_days = Keyword.get(opts, :max_age_days, 365)

    with :ok <- validate_weights(weights),
         :ok <- validate_subject(subject) do
      cutoff = Date.add(Date.utc_today(), -max_age_days)

      results =
        candidates
        |> Enum.reject(fn c -> Date.compare(c.sold_on, cutoff) == :lt end)
        |> Enum.reject(fn c -> c.id == subject.id end)
        |> Enum.map(fn c -> %{property: c, score: similarity(subject, c, weights)} end)
        |> Enum.sort_by(fn s -> s.score end, :desc)
        |> Enum.take(n)

      {:ok, results}
    end
  end

  defp similarity(subject, candidate, weights) do
    postcode_score = if subject.postcode == candidate.postcode, do: 1.0, else: 0.0
    bedroom_score = score_proximity(subject.bedrooms, candidate.bedrooms, 5)
    area_score = score_proximity(subject.floor_area_sqm, candidate.floor_area_sqm, subject.floor_area_sqm)
    recency_score = recency_score(candidate.sold_on)
    type_score = if subject.property_type == candidate.property_type, do: 1.0, else: 0.0

    postcode_score * weights.postcode +
      bedroom_score * weights.bedrooms +
      area_score * weights.floor_area +
      recency_score * weights.recency +
      type_score * weights.property_type
  end

  defp score_proximity(_a, _b, 0), do: 0.0

  defp score_proximity(a, b, scale) do
    diff = abs(a - b) / scale
    max(1.0 - diff, 0.0)
  end

  defp recency_score(sold_on) do
    days_ago = Date.diff(Date.utc_today(), sold_on)
    max(1.0 - days_ago / 365.0, 0.0)
  end

  defp validate_weights(weights) when is_map(weights) do
    required = ~w(postcode bedrooms floor_area recency property_type)a
    missing = Enum.reject(required, fn k -> Map.has_key?(weights, k) end)

    if missing != [] do
      {:error, "missing weight keys: #{Enum.join(missing, ", ")}"}
    else
      total = weights |> Map.values() |> Enum.sum()

      if abs(total - 1.0) < 0.001 do
        :ok
      else
        {:error, "weights must sum to 1.0, got #{Float.round(total, 4)}"}
      end
    end
  end

  defp validate_weights(_), do: {:error, "weights must be a map"}

  defp validate_subject(%{id: id, postcode: pc, bedrooms: bed, floor_area_sqm: area, property_type: pt})
       when is_binary(id) and id != "" and is_binary(pc) and is_integer(bed) and bed >= 0 and
              is_float(area) and area > 0.0 and pt in [:house, :apartment, :townhouse],
       do: :ok

  defp validate_subject(_), do: {:error, "subject property is missing required fields"}
end
```
