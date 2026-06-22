```elixir
defmodule Moderation.ContentReviewer do
  @moduledoc """
  Runs user-submitted content through a sequential moderation pipeline.
  Each check is independent and returns a structured verdict. The pipeline
  short-circuits on a hard block and accumulates warnings otherwise.
  """

  alias Moderation.{SpamDetector, ToxicityClassifier, LinkScanner, ProfanityFilter}

  @type content :: %{
          text: String.t(),
          author_id: String.t(),
          attachments: [map()]
        }

  @type verdict :: :approved | :blocked | :flagged_for_review

  @type review_result :: %{
          verdict: verdict(),
          checks: [check_result()],
          block_reason: atom() | nil
        }

  @type check_result :: %{
          check: atom(),
          passed: boolean(),
          severity: :info | :warn | :block,
          detail: map()
        }

  @spec review(content()) :: review_result()
  def review(content) when is_map(content) do
    checks = [
      &run_spam_check/1,
      &run_toxicity_check/1,
      &run_link_scan/1,
      &run_profanity_check/1
    ]

    run_pipeline(content, checks)
  end

  @spec run_pipeline(content(), [(content() -> check_result())]) :: review_result()
  defp run_pipeline(content, checks) do
    Enum.reduce_while(checks, %{checks: [], block_reason: nil}, fn check_fn, acc ->
      result = check_fn.(content)

      updated = Map.update!(acc, :checks, &[result | &1])

      case result.severity do
        :block -> {:halt, %{updated | block_reason: result.check}}
        _ -> {:cont, updated}
      end
    end)
    |> finalize()
  end

  @spec finalize(%{checks: [check_result()], block_reason: atom() | nil}) :: review_result()
  defp finalize(%{block_reason: reason} = acc) when not is_nil(reason) do
    %{verdict: :blocked, checks: Enum.reverse(acc.checks), block_reason: reason}
  end

  defp finalize(acc) do
    has_warnings = Enum.any?(acc.checks, &(&1.severity == :warn))
    verdict = if has_warnings, do: :flagged_for_review, else: :approved

    %{verdict: verdict, checks: Enum.reverse(acc.checks), block_reason: nil}
  end

  @spec run_spam_check(content()) :: check_result()
  defp run_spam_check(content) do
    {passed, detail} = SpamDetector.check(content.text, content.author_id)
    severity = if passed, do: :info, else: :block
    %{check: :spam, passed: passed, severity: severity, detail: detail}
  end

  @spec run_toxicity_check(content()) :: check_result()
  defp run_toxicity_check(content) do
    {score, label} = ToxicityClassifier.score(content.text)
    passed = score < 0.85
    severity = cond do
      score >= 0.85 -> :block
      score >= 0.60 -> :warn
      true -> :info
    end
    %{check: :toxicity, passed: passed, severity: severity, detail: %{score: score, label: label}}
  end

  @spec run_link_scan(content()) :: check_result()
  defp run_link_scan(content) do
    {safe, flagged_urls} = LinkScanner.scan(content.text)
    severity = if safe, do: :info, else: :block
    %{check: :links, passed: safe, severity: severity, detail: %{flagged: flagged_urls}}
  end

  @spec run_profanity_check(content()) :: check_result()
  defp run_profanity_check(content) do
    {clean, matches} = ProfanityFilter.check(content.text)
    severity = if clean, do: :info, else: :warn
    %{check: :profanity, passed: clean, severity: severity, detail: %{matches: matches}}
  end
end
```
