```elixir
defmodule Nlp.Text.TokenizerPipeline do
  @moduledoc """
  A composable text tokenisation pipeline for natural language processing.
  Each stage is a pure transformation function applied sequentially.
  Pipelines are assembled at call time and may be partially composed.
  """

  @type token :: String.t()
  @type stage :: (String.t() -> String.t()) | ([token()] -> [token()])
  @type pipeline_result :: {:ok, [token()]} | {:error, String.t()}

  @doc """
  Runs `text` through a sequence of normalisation and tokenisation stages.
  Returns `{:ok, tokens}` or `{:error, reason}` on invalid input.
  """
  @spec tokenize(String.t(), keyword()) :: pipeline_result()
  def tokenize(text, opts \\ []) when is_binary(text) do
    stages = Keyword.get(opts, :stages, default_stages())

    try do
      tokens =
        text
        |> apply_string_stages(string_stages(stages))
        |> split_into_tokens()
        |> apply_token_stages(token_stages(stages))

      {:ok, tokens}
    rescue
      e -> {:error, "tokenisation failed: #{Exception.message(e)}"}
    end
  end

  @doc """
  Lowercases all text.
  """
  @spec lowercase(String.t()) :: String.t()
  def lowercase(text) when is_binary(text), do: String.downcase(text)

  @doc """
  Strips punctuation characters from the text.
  """
  @spec strip_punctuation(String.t()) :: String.t()
  def strip_punctuation(text) when is_binary(text) do
    String.replace(text, ~r/[^\w\s]/u, "")
  end

  @doc """
  Collapses multiple consecutive whitespace characters into a single space.
  """
  @spec normalise_whitespace(String.t()) :: String.t()
  def normalise_whitespace(text) when is_binary(text) do
    text |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  @doc """
  Removes stopwords from a token list using the default English stopword set.
  """
  @spec remove_stopwords([token()]) :: [token()]
  def remove_stopwords(tokens) when is_list(tokens) do
    Enum.reject(tokens, fn t -> t in stopwords() end)
  end

  @doc """
  Removes tokens shorter than `min_length` characters.
  """
  @spec filter_short_tokens([token()], pos_integer()) :: [token()]
  def filter_short_tokens(tokens, min_length \\ 2)
      when is_list(tokens) and is_integer(min_length) and min_length > 0 do
    Enum.reject(tokens, fn t -> String.length(t) < min_length end)
  end

  @doc """
  Returns the default tokenisation stage pipeline.
  """
  @spec default_stages() :: [atom()]
  def default_stages do
    [:lowercase, :strip_punctuation, :normalise_whitespace, :remove_stopwords, :filter_short]
  end

  defp apply_string_stages(text, stages) do
    Enum.reduce(stages, text, fn stage, acc -> stage.(acc) end)
  end

  defp apply_token_stages(tokens, stages) do
    Enum.reduce(stages, tokens, fn stage, acc -> stage.(acc) end)
  end

  defp split_into_tokens(text) do
    String.split(text, ~r/\s+/, trim: true)
  end

  defp string_stages(stage_names) do
    Enum.flat_map(stage_names, fn
      :lowercase -> [&lowercase/1]
      :strip_punctuation -> [&strip_punctuation/1]
      :normalise_whitespace -> [&normalise_whitespace/1]
      _ -> []
    end)
  end

  defp token_stages(stage_names) do
    Enum.flat_map(stage_names, fn
      :remove_stopwords -> [&remove_stopwords/1]
      :filter_short -> [&filter_short_tokens/1]
      _ -> []
    end)
  end

  defp stopwords do
    ~w(a an the is are was were be been being have has had do does did will would shall should may might must can could)
  end
end
```
