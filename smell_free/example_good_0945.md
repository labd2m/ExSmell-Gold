```elixir
defmodule Analytics.SessionSegmenter do
  @moduledoc """
  Segments user sessions into behavioural groups based on interaction
  signals. Each session is classified into exactly one segment using a
  prioritised rule set. Rules are pure predicate functions so adding
  new segments requires only appending to the rule list without touching
  existing logic. All computation is stateless and operates on plain maps.
  """

  @type session :: %{
          page_views: non_neg_integer(),
          events_fired: non_neg_integer(),
          duration_seconds: non_neg_integer(),
          converted: boolean(),
          return_visitor: boolean(),
          referrer_source: String.t() | nil
        }

  @type segment ::
          :converted_buyer
          | :engaged_prospect
          | :return_browser
          | :organic_newcomer
          | :paid_newcomer
          | :bounce

  @type segment_result :: %{segment: segment(), confidence: float(), matched_rule: String.t()}

  @paid_sources ~w(google_ads facebook_ads bing_ads)

  @rules [
    {"converted_buyer",
     fn s -> s.converted end,
     1.0},
    {"engaged_prospect",
     fn s -> s.page_views >= 4 and s.events_fired >= 3 and not s.converted end,
     0.9},
    {"return_browser",
     fn s -> s.return_visitor and s.page_views >= 2 end,
     0.85},
    {"paid_newcomer",
     fn s -> not s.return_visitor and s.referrer_source in @paid_sources end,
     0.8},
    {"organic_newcomer",
     fn s -> not s.return_visitor and s.page_views >= 2 end,
     0.7},
    {"bounce",
     fn s -> s.page_views == 1 and s.duration_seconds < 30 end,
     0.95}
  ]

  @doc """
  Classifies `session` into a segment. Returns the first matching rule
  in priority order, or `{:error, :unclassified}` when no rule matches.
  """
  @spec classify(session()) :: {:ok, segment_result()} | {:error, :unclassified}
  def classify(%{} = session) do
    result =
      Enum.find_value(@rules, fn {rule_name, predicate, confidence} ->
        if predicate.(session) do
          %{
            segment: String.to_existing_atom(rule_name),
            confidence: confidence,
            matched_rule: rule_name
          }
        end
      end)

    case result do
      nil -> {:error, :unclassified}
      seg -> {:ok, seg}
    end
  end

  @doc "Classifies a list of sessions and returns counts per segment."
  @spec distribution([session()]) :: %{segment() => non_neg_integer()}
  def distribution(sessions) when is_list(sessions) do
    base = Map.new(segment_names(), fn s -> {s, 0} end)

    Enum.reduce(sessions, base, fn session, acc ->
      case classify(session) do
        {:ok, %{segment: seg}} -> Map.update!(acc, seg, &(&1 + 1))
        {:error, :unclassified} -> acc
      end
    end)
  end

  @doc "Returns all defined segment names in priority order."
  @spec segment_names() :: [segment()]
  def segment_names do
    Enum.map(@rules, fn {name, _pred, _conf} -> String.to_existing_atom(name) end)
  end

  @doc "Returns the confidence score for the named segment rule."
  @spec confidence_for(segment()) :: float() | nil
  def confidence_for(segment) when is_atom(segment) do
    name = Atom.to_string(segment)
    Enum.find_value(@rules, fn {rule_name, _pred, confidence} ->
      if rule_name == name, do: confidence
    end)
  end
end
```
