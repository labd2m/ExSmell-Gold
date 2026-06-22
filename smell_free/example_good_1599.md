```elixir
defmodule Segmentation.Criterion do
  @moduledoc """
  A single matching rule within a customer segment definition.
  """

  @type operator :: :eq | :neq | :gt | :lt | :gte | :lte | :in | :contains

  @type t :: %__MODULE__{
          field: atom(),
          operator: operator(),
          value: term()
        }

  defstruct [:field, :operator, :value]
end

defmodule Segmentation.Segment do
  alias Segmentation.Criterion

  @moduledoc """
  A named customer segment composed of criteria joined by a logical operator.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          logic: :all | :any,
          criteria: [Criterion.t()]
        }

  defstruct [:id, :name, logic: :all, criteria: []]
end

defmodule Segmentation.Matcher do
  alias Segmentation.{Criterion, Segment}

  @moduledoc """
  Evaluates whether a customer profile map matches a given segment definition.
  Supports composite logic (`all` requiring every criterion, `any` requiring one).
  """

  @spec matches?(map(), Segment.t()) :: boolean()
  def matches?(profile, %Segment{logic: :all, criteria: criteria}) when is_map(profile) do
    Enum.all?(criteria, &criterion_matches?(profile, &1))
  end

  def matches?(profile, %Segment{logic: :any, criteria: criteria}) when is_map(profile) do
    Enum.any?(criteria, &criterion_matches?(profile, &1))
  end

  @spec matching_segments(map(), [Segment.t()]) :: [Segment.t()]
  def matching_segments(profile, segments) when is_map(profile) and is_list(segments) do
    Enum.filter(segments, &matches?(profile, &1))
  end

  defp criterion_matches?(profile, %Criterion{field: field, operator: op, value: expected}) do
    case Map.fetch(profile, field) do
      {:ok, actual} -> evaluate(op, actual, expected)
      :error -> false
    end
  end

  defp evaluate(:eq, actual, expected), do: actual == expected
  defp evaluate(:neq, actual, expected), do: actual != expected

  defp evaluate(:gt, actual, expected)
       when is_number(actual) and is_number(expected), do: actual > expected

  defp evaluate(:lt, actual, expected)
       when is_number(actual) and is_number(expected), do: actual < expected

  defp evaluate(:gte, actual, expected)
       when is_number(actual) and is_number(expected), do: actual >= expected

  defp evaluate(:lte, actual, expected)
       when is_number(actual) and is_number(expected), do: actual <= expected

  defp evaluate(:in, actual, expected) when is_list(expected), do: actual in expected

  defp evaluate(:contains, actual, expected)
       when is_binary(actual) and is_binary(expected), do: String.contains?(actual, expected)

  defp evaluate(:contains, actual, expected) when is_list(actual), do: expected in actual

  defp evaluate(_op, _actual, _expected), do: false
end
```
