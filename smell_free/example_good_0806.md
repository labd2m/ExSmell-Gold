```elixir
defmodule MyApp.Content.ContentModerator do
  @moduledoc """
  Screens user-generated content against a configurable set of moderation
  rules before publication. Rules operate on a typed `ContentItem` struct
  and produce structured verdicts with the matched rule name and an
  operator-facing reason. Multiple rules may match; the strictest verdict
  takes precedence.

  The moderation pipeline is synchronous and purely functional, making it
  straightforward to unit-test each rule in isolation.
  """

  @type content_type :: :post | :comment | :bio | :product_description
  @type verdict :: :approved | :flagged | :rejected
  @type rule_result :: %{rule: atom(), verdict: verdict(), reason: String.t()}

  @type content_item :: %{
          required(:id) => String.t(),
          required(:type) => content_type(),
          required(:body) => String.t(),
          required(:author_id) => String.t(),
          optional(:title) => String.t()
        }

  @type moderation_result :: %{
          verdict: verdict(),
          rule_results: [rule_result()],
          auto_actioned: boolean()
        }

  @rules [
    {:length_limit, &__MODULE__.rule_length_limit/1},
    {:blocked_keywords, &__MODULE__.rule_blocked_keywords/1},
    {:url_spam, &__MODULE__.rule_url_spam/1},
    {:all_caps, &__MODULE__.rule_all_caps/1}
  ]

  @blocked_words ~w(
    spam casino lottery jackpot
    click-here free-money wire-transfer
  )

  @doc """
  Screens `item` against all registered moderation rules and returns an
  aggregated verdict. Auto-actions (flagging or rejecting) are applied
  when the verdict is not `:approved`.
  """
  @spec moderate(content_item()) :: moderation_result()
  def moderate(%{} = item) when is_map(item) do
    rule_results =
      Enum.flat_map(@rules, fn {_name, fun} ->
        case fun.(item) do
          nil -> []
          result -> [result]
        end
      end)

    verdict = aggregate_verdict(rule_results)
    auto_actioned = verdict != :approved

    %{verdict: verdict, rule_results: rule_results, auto_actioned: auto_actioned}
  end

  @doc false
  @spec rule_length_limit(content_item()) :: rule_result() | nil
  def rule_length_limit(%{body: body, type: type}) do
    limit = max_length(type)

    if String.length(body) > limit do
      %{rule: :length_limit, verdict: :rejected,
        reason: "Body exceeds maximum length of #{limit} characters for #{type}"}
    end
  end

  @doc false
  @spec rule_blocked_keywords(content_item()) :: rule_result() | nil
  def rule_blocked_keywords(%{body: body}) do
    lower = String.downcase(body)

    matched =
      Enum.filter(@blocked_words, &String.contains?(lower, &1))

    unless matched == [] do
      %{rule: :blocked_keywords, verdict: :flagged,
        reason: "Contains blocked keywords: #{Enum.join(matched, ", ")}"}
    end
  end

  @doc false
  @spec rule_url_spam(content_item()) :: rule_result() | nil
  def rule_url_spam(%{body: body}) do
    url_count = body |> String.scan(~r/https?:\/\//) |> length()

    cond do
      url_count >= 5 ->
        %{rule: :url_spam, verdict: :rejected, reason: "Excessive URLs (#{url_count})"}

      url_count >= 3 ->
        %{rule: :url_spam, verdict: :flagged, reason: "Multiple URLs detected (#{url_count})"}

      true ->
        nil
    end
  end

  @doc false
  @spec rule_all_caps(content_item()) :: rule_result() | nil
  def rule_all_caps(%{body: body}) do
    letters = String.replace(body, ~r/[^a-zA-Z]/, "")

    if String.length(letters) >= 20 and letters == String.upcase(letters) do
      %{rule: :all_caps, verdict: :flagged, reason: "Content is entirely uppercase"}
    end
  end

  @spec aggregate_verdict([rule_result()]) :: verdict()
  defp aggregate_verdict([]), do: :approved

  defp aggregate_verdict(results) do
    if Enum.any?(results, &(&1.verdict == :rejected)), do: :rejected, else: :flagged
  end

  @spec max_length(content_type()) :: pos_integer()
  defp max_length(:comment), do: 2_000
  defp max_length(:bio), do: 500
  defp max_length(:product_description), do: 5_000
  defp max_length(_), do: 10_000
end
```
