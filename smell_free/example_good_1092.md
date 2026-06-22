```elixir
defmodule Search.IndexingPipeline do
  @moduledoc """
  Processes raw content documents through tokenization, normalization,
  and index term extraction before writing to the search index.
  """

  alias Search.{Tokenizer, Normalizer, StopwordFilter, IndexWriter}

  @type raw_document :: %{
          id: String.t(),
          title: String.t(),
          body: String.t(),
          tags: [String.t()],
          locale: String.t()
        }

  @type indexed_document :: %{
          id: String.t(),
          terms: [String.t()],
          field_weights: %{String.t() => float()}
        }

  @field_weights %{"title" => 3.0, "tags" => 2.0, "body" => 1.0}

  @spec index(raw_document()) :: {:ok, indexed_document()} | {:error, atom()}
  def index(%{locale: locale} = doc) when is_binary(locale) do
    with {:ok, title_terms} <- process_field(doc.title, locale),
         {:ok, body_terms} <- process_field(doc.body, locale),
         {:ok, tag_terms} <- process_tags(doc.tags) do
      terms = deduplicate(title_terms ++ body_terms ++ tag_terms)
      weights = compute_weights(title_terms, body_terms, tag_terms)
      indexed = %{id: doc.id, terms: terms, field_weights: weights}
      IndexWriter.write(indexed)
      {:ok, indexed}
    end
  end

  @spec index_batch([raw_document()]) :: %{
          indexed: non_neg_integer(),
          failed: non_neg_integer()
        }
  def index_batch(documents) when is_list(documents) do
    Enum.reduce(documents, %{indexed: 0, failed: 0}, fn doc, acc ->
      case index(doc) do
        {:ok, _} -> Map.update!(acc, :indexed, &(&1 + 1))
        {:error, _} -> Map.update!(acc, :failed, &(&1 + 1))
      end
    end)
  end

  @spec process_field(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  defp process_field(text, locale) when is_binary(text) do
    with {:ok, tokens} <- Tokenizer.tokenize(text, locale),
         {:ok, normalized} <- Normalizer.normalize(tokens, locale) do
      {:ok, StopwordFilter.filter(normalized, locale)}
    end
  end

  defp process_field(_, _), do: {:error, :invalid_field}

  @spec process_tags([String.t()]) :: {:ok, [String.t()]} | {:error, atom()}
  defp process_tags(tags) when is_list(tags) do
    processed =
      tags
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, processed}
  end

  defp process_tags(_), do: {:error, :invalid_tags}

  @spec deduplicate([String.t()]) :: [String.t()]
  defp deduplicate(terms), do: Enum.uniq(terms)

  @spec compute_weights([String.t()], [String.t()], [String.t()]) :: %{String.t() => float()}
  defp compute_weights(title_terms, body_terms, tag_terms) do
    title_score = length(title_terms) * @field_weights["title"]
    body_score = length(body_terms) * @field_weights["body"]
    tag_score = length(tag_terms) * @field_weights["tags"]

    %{
      "title" => title_score,
      "body" => body_score,
      "tags" => tag_score
    }
  end
end
```
