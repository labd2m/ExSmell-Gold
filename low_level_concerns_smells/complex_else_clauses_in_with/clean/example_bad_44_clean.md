```elixir
defmodule MLPlatform.PredictionRunner do
  @moduledoc """
  Runs predictions against deployed ML models: model resolution,
  feature extraction, input validation, inference, and result persistence.
  """

  alias MLPlatform.{
    ModelRegistry,
    FeaturePipeline,
    InputValidator,
    InferenceEngine,
    ResultStore
  }

  require Logger

  @doc """
  Runs a prediction for `request` against model `model_name`.

  `request` must contain `:entity_id` and `:context`.

  Returns `{:ok, prediction}` or a structured error.
  """
  @spec run_prediction(String.t(), map()) ::
          {:ok, map()}
          | {:error, :model_not_deployed}
          | {:error, :feature_extraction_failed, String.t()}
          | {:error, :invalid_input, list()}
          | {:error, :inference_failed}
          | {:error, :result_store_failed}
  def run_prediction(model_name, request) do
    with {:ok, model}    <- ModelRegistry.fetch_deployed(model_name),
         {:ok, features} <- FeaturePipeline.extract(request.entity_id, request.context, model.feature_set),
         :ok             <- InputValidator.validate(features, model.input_schema),
         {:ok, output}   <- InferenceEngine.infer(model, features),
         {:ok, record}   <- ResultStore.persist(%{
                              model_name: model_name,
                              model_version: model.version,
                              entity_id:  request.entity_id,
                              output:     output,
                              run_at:     DateTime.utc_now()
                            }) do
      Logger.info("Prediction #{record.id} completed for entity #{request.entity_id} using #{model_name}")
      {:ok, %{
        prediction_id: record.id,
        model:         model_name,
        version:       model.version,
        output:        output,
        run_at:        record.run_at
      }}
    else
      {:error, :not_deployed} ->
        Logger.warn("Model #{model_name} is not currently deployed")
        {:error, :model_not_deployed}

      {:error, :features, source} ->
        Logger.error("Feature extraction failed at source: #{source}")
        {:error, :feature_extraction_failed, source}

      {:error, :validation, violations} ->
        Logger.warn("Input validation violations: #{inspect(violations)}")
        {:error, :invalid_input, violations}

      {:error, :inference, detail} ->
        Logger.error("Inference engine error: #{inspect(detail)}")
        {:error, :inference_failed}

      {:error, :store} ->
        Logger.error("Prediction result could not be persisted")
        {:error, :result_store_failed}
    end
  end
end
```
