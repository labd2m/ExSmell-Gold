```elixir
defmodule Genomics.Variants.AnnotationPipeline do
  @moduledoc """
  Annotates genomic variant records with functional impact predictions,
  population frequency lookups, and clinical significance classifications.
  Each annotation stage is independently tested and composed at call time.
  """

  alias Genomics.Variants.{Variant, Annotation, FrequencyDatabase, ClinicalDatabase}

  @type annotated :: %{variant: Variant.t(), annotation: Annotation.t()}
  @type pipeline_result :: {:ok, annotated()} | {:error, String.t()}

  @doc """
  Runs `variant` through the full annotation pipeline.
  Returns `{:ok, annotated}` on success or `{:error, reason}` on failure.
  """
  @spec annotate(Variant.t(), keyword()) :: pipeline_result()
  def annotate(%Variant{} = variant, opts \\ []) do
    freq_db = Keyword.get(opts, :freq_db, FrequencyDatabase)
    clin_db = Keyword.get(opts, :clin_db, ClinicalDatabase)

    with :ok <- validate_variant(variant),
         {:ok, annotation} <- initialise_annotation(variant),
         {:ok, with_impact} <- add_functional_impact(annotation, variant),
         {:ok, with_freq} <- add_population_frequency(with_impact, variant, freq_db),
         {:ok, with_clin} <- add_clinical_significance(with_freq, variant, clin_db) do
      {:ok, %{variant: variant, annotation: with_clin}}
    end
  end

  @doc """
  Annotates a batch of variants concurrently.
  Returns grouped results with successful annotations and per-variant errors.
  """
  @spec annotate_batch([Variant.t()], keyword()) ::
          %{ok: [annotated()], errors: %{String.t() => String.t()}}
  def annotate_batch(variants, opts \\ []) when is_list(variants) do
    variants
    |> Task.async_stream(fn v -> {v.id, annotate(v, opts)} end,
      ordered: false,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{ok: [], errors: %{}}, &collect_result/2)
  end

  defp initialise_annotation(variant) do
    {:ok, %Annotation{variant_id: variant.id, created_at: DateTime.utc_now()}}
  end

  defp add_functional_impact(annotation, %Variant{consequence: consequence}) do
    impact = classify_impact(consequence)
    {:ok, %{annotation | functional_impact: impact}}
  end

  defp add_population_frequency(annotation, variant, freq_db) do
    case freq_db.lookup(variant.chromosome, variant.position, variant.allele) do
      {:ok, frequency} -> {:ok, %{annotation | population_frequency: frequency}}
      {:error, :not_found} -> {:ok, %{annotation | population_frequency: nil}}
      {:error, reason} -> {:error, "frequency lookup failed: #{reason}"}
    end
  end

  defp add_clinical_significance(annotation, variant, clin_db) do
    case clin_db.classify(variant.id) do
      {:ok, significance} -> {:ok, %{annotation | clinical_significance: significance}}
      {:error, :unclassified} -> {:ok, %{annotation | clinical_significance: :unknown}}
      {:error, reason} -> {:error, "clinical classification failed: #{reason}"}
    end
  end

  defp classify_impact(:frameshift), do: :high
  defp classify_impact(:stop_gained), do: :high
  defp classify_impact(:missense), do: :moderate
  defp classify_impact(:synonymous), do: :low
  defp classify_impact(:intronic), do: :modifier
  defp classify_impact(_other), do: :modifier

  defp validate_variant(%Variant{id: id, chromosome: chr, position: pos, allele: allele})
       when is_binary(id) and id != "" and
              is_binary(chr) and chr != "" and
              is_integer(pos) and pos > 0 and
              is_binary(allele) and allele != "",
       do: :ok

  defp validate_variant(_), do: {:error, "variant must have id, chromosome, position, and allele"}

  defp collect_result({:ok, {_id, {:ok, annotated}}}, acc) do
    %{acc | ok: [annotated | acc.ok]}
  end

  defp collect_result({:ok, {id, {:error, reason}}}, acc) do
    %{acc | errors: Map.put(acc.errors, id, reason)}
  end

  defp collect_result({:exit, _}, acc), do: acc
end
```
