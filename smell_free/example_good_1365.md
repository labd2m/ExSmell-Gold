```elixir
defmodule Recommendations.Item do
  @moduledoc """
  A product or content item that can be recommended.
  Items carry a sparse feature vector used for similarity scoring.
  """

  @enforce_keys [:id, :category, :features]
  defstruct [:id, :category, :features, :score_boost]

  @type t :: %__MODULE__{
          id: String.t(),
          category: atom(),
          features: %{atom() => float()},
          score_boost: float() | nil
        }

  @spec new(String.t(), atom(), %{atom() => float()}, keyword()) :: t()
  def new(id, category, features, opts \\ [])
      when is_binary(id) and is_atom(category) and is_map(features) do
    %__MODULE__{
      id: id,
      category: category,
      features: features,
      score_boost: Keyword.get(opts, :score_boost)
    }
  end
end

defmodule Recommendations.Scorer do
  @moduledoc """
  Computes cosine similarity between a user preference vector and a set of
  candidate items. Items are ranked by similarity score, with optional
  category filtering and per-item score boosts applied before sorting.
  """

  alias Recommendations.Item

  @type preference_vector :: %{atom() => float()}
  @type scored_item :: %{item: Item.t(), score: float()}

  @spec rank(list(Item.t()), preference_vector(), keyword()) :: list(scored_item())
  def rank(items, preferences, opts \\ [])
      when is_list(items) and is_map(preferences) do
    only_categories = Keyword.get(opts, :categories)
    limit = Keyword.get(opts, :limit, 10)

    items
    |> apply_category_filter(only_categories)
    |> Enum.map(&score_item(&1, preferences))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @spec cosine_similarity(preference_vector(), preference_vector()) :: float()
  def cosine_similarity(vec_a, vec_b) when is_map(vec_a) and is_map(vec_b) do
    shared_keys = MapSet.intersection(MapSet.new(Map.keys(vec_a)), MapSet.new(Map.keys(vec_b)))

    dot = Enum.reduce(shared_keys, 0.0, fn k, acc -> acc + Map.fetch!(vec_a, k) * Map.fetch!(vec_b, k) end)
    mag_a = magnitude(vec_a)
    mag_b = magnitude(vec_b)

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  defp score_item(%Item{features: features, score_boost: boost} = item, preferences) do
    base_score = cosine_similarity(features, preferences)
    boosted_score = base_score + (boost || 0.0)
    %{item: item, score: Float.round(boosted_score, 6)}
  end

  defp apply_category_filter(items, nil), do: items

  defp apply_category_filter(items, categories) when is_list(categories) do
    category_set = MapSet.new(categories)
    Enum.filter(items, fn %Item{category: cat} -> MapSet.member?(category_set, cat) end)
  end

  defp magnitude(vec) do
    vec |> Map.values() |> Enum.reduce(0.0, fn v, acc -> acc + v * v end) |> :math.sqrt()
  end
end

defmodule Recommendations.PersonalizedFeed do
  @moduledoc """
  Builds a personalized content feed for a user by combining collaborative
  filtering signals with their explicitly stated preferences.
  """

  alias Recommendations.{Item, Scorer}

  @type user_profile :: %{preferences: Scorer.preference_vector(), viewed_ids: list(String.t())}

  @spec build(list(Item.t()), user_profile(), keyword()) :: list(Scorer.scored_item())
  def build(catalog, %{preferences: prefs, viewed_ids: viewed}, opts \\ [])
      when is_list(catalog) and is_map(prefs) and is_list(viewed) do
    viewed_set = MapSet.new(viewed)

    catalog
    |> Enum.reject(fn %Item{id: id} -> MapSet.member?(viewed_set, id) end)
    |> Scorer.rank(prefs, opts)
  end

  @spec similar_to(Item.t(), list(Item.t()), keyword()) :: list(Scorer.scored_item())
  def similar_to(%Item{features: features} = target, catalog, opts \\ []) do
    catalog
    |> Enum.reject(fn %Item{id: id} -> id == target.id end)
    |> Scorer.rank(features, opts)
  end
end
```
