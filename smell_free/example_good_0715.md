```elixir
defmodule Platform.ContentModerator do
  @moduledoc """
  A composable content moderation pipeline that applies a sequence of
  rule-based and pattern-based checks to user-submitted text.

  Each check returns `:pass` or `{:flag, reason}`. The pipeline short-circuits
  on the first flag by default, or collects all flags when configured to do so.
  """

  @type check_result :: :pass | {:flag, atom(), String.t()}
  @type text :: String.t()
  @type moderation_result :: :approved | {:flagged, [%{reason: atom(), detail: String.t()}]}

  @profanity_list ~w[
    badword1 badword2 badword3
  ]

  @url_pattern ~r/https?:\/\/[^\s]+/i
  @email_pattern ~r/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/

  @doc """
  Runs the full moderation pipeline against `text`.

  Returns `:approved` or `{:flagged, flags}` with a list of flag details.
  Pass `stop_on_first: true` to short-circuit after the first flag.
  """
  @spec moderate(text(), keyword()) :: moderation_result()
  def moderate(text, opts \\ []) when is_binary(text) do
    stop_on_first = Keyword.get(opts, :stop_on_first, false)
    checks = Keyword.get(opts, :checks, default_checks())

    flags =
      Enum.reduce_while(checks, [], fn check_fn, acc ->
        case check_fn.(text) do
          :pass ->
            {:cont, acc}

          {:flag, reason, detail} ->
            new_acc = [%{reason: reason, detail: detail} | acc]
            if stop_on_first, do: {:halt, new_acc}, else: {:cont, new_acc}
        end
      end)

    if flags == [], do: :approved, else: {:flagged, Enum.reverse(flags)}
  end

  @doc "Returns a check function for profanity based on a custom word list."
  @spec profanity_check([String.t()]) :: (text() -> check_result())
  def profanity_check(word_list \\ @profanity_list) do
    pattern = Regex.compile!(Enum.join(word_list, "|"), [:caseless])

    fn text ->
      case Regex.run(pattern, text) do
        nil -> :pass
        [match | _] -> {:flag, :profanity, "Matched term: #{match}"}
      end
    end
  end

  @doc "Returns a check function that flags text exceeding `max_length` characters."
  @spec length_check(pos_integer()) :: (text() -> check_result())
  def length_check(max_length) when is_integer(max_length) and max_length > 0 do
    fn text ->
      if String.length(text) <= max_length do
        :pass
      else
        {:flag, :too_long, "Content exceeds #{max_length} characters"}
      end
    end
  end

  @doc "Returns a check that flags text containing URLs."
  @spec url_check() :: (text() -> check_result())
  def url_check do
    fn text ->
      if Regex.match?(@url_pattern, text) do
        {:flag, :contains_url, "Content contains external URLs"}
      else
        :pass
      end
    end
  end

  @doc "Returns a check that flags text containing email addresses."
  @spec email_check() :: (text() -> check_result())
  def email_check do
    fn text ->
      if Regex.match?(@email_pattern, text) do
        {:flag, :contains_email, "Content contains email addresses"}
      else
        :pass
      end
    end
  end

  @doc "Returns a check that flags repeated characters suggesting spam."
  @spec repetition_check(pos_integer()) :: (text() -> check_result())
  def repetition_check(threshold \\ 6) do
    pattern = Regex.compile!("(.)\\1{#{threshold - 1},}")

    fn text ->
      if Regex.match?(pattern, text) do
        {:flag, :repetitive_content, "Content contains excessive character repetition"}
      else
        :pass
      end
    end
  end

  defp default_checks do
    [
      length_check(10_000),
      profanity_check(),
      repetition_check()
    ]
  end
end
```
