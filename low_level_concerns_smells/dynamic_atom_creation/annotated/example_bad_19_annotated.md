# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `InferenceEndpoint.build_prediction/2`, line where `String.to_atom/1` converts the label string from the model output |
| **Affected function(s)** | `InferenceEndpoint.build_prediction/2` |
| **Short explanation** | The predicted class label is returned as a string from an external model serving API response. Converting it directly to an atom means that every label variant produced by the model—including confidence-weighted outputs, multi-label classifiers, or retrained models with new classes—permanently occupies an atom slot. |

```elixir
defmodule MyApp.ML.InferenceEndpoint do
  @moduledoc """
  Client for the internal model serving API.
  Sends feature vectors to the ML inference cluster and returns
  structured prediction results for downstream business logic.
  """

  require Logger

  alias MyApp.ML.{FeatureExtractor, ModelRegistry, InferenceCache}

  @default_model_version "stable"
  @request_timeout_ms 3_000
  @max_retries 2

  @doc """
  Runs inference for the given input map using the specified model name.
  Returns a structured prediction map.
  """
  @spec predict(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def predict(model_name, input, opts \\ []) do
    model_version = Keyword.get(opts, :version, @default_model_version)
    use_cache = Keyword.get(opts, :cache, true)
    cache_key = build_cache_key(model_name, model_version, input)

    if use_cache do
      case InferenceCache.get(cache_key) do
        {:ok, cached} ->
          Logger.debug("Inference cache hit", model: model_name)
          {:ok, cached}

        {:miss, _} ->
          run_inference(model_name, model_version, input, cache_key)
      end
    else
      run_inference(model_name, model_version, input, cache_key)
    end
  end

  defp run_inference(model_name, model_version, input, cache_key) do
    with {:ok, endpoint} <- ModelRegistry.get_endpoint(model_name, model_version),
         {:ok, features} <- FeatureExtractor.extract(input),
         {:ok, response} <- call_model(endpoint, features) do
      prediction = build_prediction(response, model_name)
      InferenceCache.put(cache_key, prediction)
      {:ok, prediction}
    end
  end

  defp call_model(endpoint, features) do
    body = Jason.encode!(%{instances: [features]})
    headers = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]

    case retry_post(endpoint, body, headers, @max_retries) do
      {:ok, %{status_code: 200, body: raw}} -> {:ok, Jason.decode!(raw)}
      {:ok, %{status_code: code}} -> {:error, {:model_error, code}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is used to convert the
  # predicted class label string returned by the external ML model serving API.
  # ML models can produce a wide range of label strings depending on their training
  # data, versioning, and configuration (e.g., "positive", "POSITIVE", "pos",
  # "label_0", "toxic_mild"). When models are retrained, labels can change or
  # multiply. Each unique label string from each model version permanently allocates
  # an atom. In a system with many models and frequent retraining cycles, this
  # silently fills the atom table over time.
  defp build_prediction(%{"predictions" => [[%{"label" => label, "score" => score}]]}, model_name) do
    %{
      model: model_name,
      label: String.to_atom(label),
      confidence: Float.round(score, 4),
      predicted_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  defp build_prediction(%{"predictions" => [[scores]]}, model_name) when is_map(scores) do
    {label, confidence} =
      Enum.max_by(scores, fn {_k, v} -> v end)

    %{
      model: model_name,
      label: String.to_atom(label),
      confidence: Float.round(confidence, 4),
      predicted_at: DateTime.utc_now()
    }
  end

  defp build_prediction(_, model_name) do
    Logger.warning("Unexpected prediction format from model", model: model_name)
    %{model: model_name, label: :unknown, confidence: 0.0, predicted_at: DateTime.utc_now()}
  end

  defp build_cache_key(model, version, input) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({model, version, input}))
    "inference:#{model}:#{version}:#{Base.encode16(hash, case: :lower)}"
  end

  defp retry_post(_url, _body, _headers, 0), do: {:error, :max_retries_exceeded}

  defp retry_post(url, body, headers, retries) do
    case HTTPoison.post(url, body, headers, recv_timeout: @request_timeout_ms) do
      {:ok, %{status_code: 200} = resp} -> {:ok, resp}
      {:error, _} when retries > 0 -> retry_post(url, body, headers, retries - 1)
      other -> other
    end
  end
end
```
