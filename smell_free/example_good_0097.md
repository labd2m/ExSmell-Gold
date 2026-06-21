# File: `example_good_97.md`

```elixir
defmodule Content.Pipeline do
  @moduledoc """
  Composable content transformation pipeline for processing raw user-submitted
  documents before storage or rendering.

  Each transformation stage is an independent module implementing the
  `Content.Stage` behaviour. Stages are composed at call time so that
  different pipeline configurations can be assembled per content type
  without modifying this module.
  """

  alias Content.Stage

  @type raw_document :: %{
          required(:body) => String.t(),
          required(:format) => :markdown | :html | :plain_text,
          required(:author_id) => String.t()
        }

  @type processed_document :: %{
          body: String.t(),
          sanitized_body: String.t(),
          excerpt: String.t(),
          word_count: non_neg_integer(),
          reading_time_minutes: float(),
          author_id: String.t(),
          processed_at: DateTime.t()
        }

  @type pipeline_result ::
          {:ok, processed_document()}
          | {:error, {:stage_failed, atom(), term()}}

  @default_stages [
    Content.Stage.Sanitizer,
    Content.Stage.MarkdownRenderer,
    Content.Stage.ExcerptExtractor,
    Content.Stage.WordCounter
  ]

  @doc """
  Runs `document` through the given pipeline stages in order.

  Each stage receives the accumulated document and returns either an
  updated document map or an error. Processing halts at the first
  stage failure.

  Defaults to the standard content pipeline when no stages are given.
  """
  @spec run(raw_document(), [module()]) :: pipeline_result()
  def run(document, stages \\ @default_stages)
      when is_map(document) and is_list(stages) do
    with {:ok, validated} <- validate_document(document) do
      initial = to_working_document(validated)

      Enum.reduce_while(stages, {:ok, initial}, fn stage, {:ok, doc} ->
        stage
        |> run_stage(doc)
        |> wrap_stage_result(stage)
      end)
      |> finalize()
    end
  end

  @doc """
  Returns the names of the default pipeline stages in execution order.
  """
  @spec default_stage_names() :: [atom()]
  def default_stage_names do
    Enum.map(@default_stages, fn mod ->
      mod |> Module.split() |> List.last() |> String.to_atom()
    end)
  end

  defp validate_document(%{body: body, format: format, author_id: author_id})
       when is_binary(body) and byte_size(body) > 0 and
              format in [:markdown, :html, :plain_text] and
              is_binary(author_id) and byte_size(author_id) > 0 do
    {:ok, %{body: body, format: format, author_id: author_id}}
  end

  defp validate_document(_doc), do: {:error, {:stage_failed, :validation, :invalid_document}}

  defp to_working_document(validated) do
    %{
      body: validated.body,
      format: validated.format,
      author_id: validated.author_id,
      sanitized_body: nil,
      excerpt: nil,
      word_count: 0,
      reading_time_minutes: 0.0,
      processed_at: nil
    }
  end

  defp run_stage(stage, doc) do
    stage.process(doc)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp wrap_stage_result({:ok, _doc} = ok, _stage), do: {:cont, ok}

  defp wrap_stage_result({:error, reason}, stage) do
    stage_name = stage |> Module.split() |> List.last() |> String.to_atom()
    {:halt, {:error, {:stage_failed, stage_name, reason}}}
  end

  defp finalize({:ok, doc}) do
    completed = %{doc | processed_at: DateTime.utc_now()}
    {:ok, completed}
  end

  defp finalize({:error, _} = error), do: error

  @doc """
  Computes an estimated reading time in minutes for a given word count,
  assuming an average adult reading speed of 238 words per minute.
  """
  @spec reading_time(non_neg_integer()) :: float()
  def reading_time(word_count) when is_integer(word_count) and word_count >= 0 do
    Float.round(word_count / 238.0, 1)
  end

  @doc """
  Extracts a plain-text excerpt of up to `max_chars` characters from
  processed body text, trimming cleanly at word boundaries.
  """
  @spec extract_excerpt(String.t(), pos_integer()) :: String.t()
  def extract_excerpt(body, max_chars \\ 160)
      when is_binary(body) and is_integer(max_chars) and max_chars > 0 do
    plain = body |> String.replace(~r/<[^>]+>/, "") |> String.trim()

    if String.length(plain) <= max_chars do
      plain
    else
      plain
      |> String.slice(0, max_chars)
      |> trim_to_word_boundary()
      |> Kernel.<>("…")
    end
  end

  defp trim_to_word_boundary(text) do
    case String.split(text, ~r/\s+/) |> List.pop_at(-1) do
      {_last, []} -> text
      {_, rest} -> Enum.join(rest, " ")
    end
  end
end
```
