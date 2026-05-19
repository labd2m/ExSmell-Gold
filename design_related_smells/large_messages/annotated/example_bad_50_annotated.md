# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `FeatureExtractor.extract_and_forward/2` — the `GenServer.call/3` that sends the full feature matrix to the scoring server process
- **Affected function(s):** `FeatureExtractor.extract_and_forward/2`, `ScoringServer.handle_call/3`
- **Short explanation:** A dense feature matrix — a large list of float-vector maps, one per user — is sent as the argument of a synchronous `GenServer.call` to the scoring server. The entire structure must be copied into the scoring server's heap before inference begins, blocking the extractor process and inflating end-to-end latency for real-time recommendation requests.

---

```elixir
defmodule ScoringServer do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{scored_batches: 0}, opts)
  end

  def scored_batches(pid), do: GenServer.call(pid, :scored_batches)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:scored_batches, _from, state) do
    {:reply, state.scored_batches, state}
  end

  @impl true
  def handle_call({:score_batch, model_id, feature_matrix}, _from, state) do
    Logger.info("ScoringServer: scoring #{length(feature_matrix)} feature vectors with model=#{model_id}")

    scores =
      Enum.map(feature_matrix, fn fv ->
        %{
          user_id: fv.user_id,
          score: run_inference(fv.vector),
          model_id: model_id,
          scored_at: DateTime.utc_now()
        }
      end)

    {:reply, {:ok, scores}, %{state | scored_batches: state.scored_batches + 1}}
  end

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ignored, state}

  defp run_inference(vector) do
    Enum.sum(vector) / length(vector)
  end
end

defmodule FeatureExtractor do
  require Logger

  @feature_dim 512

  @doc """
  Builds a dense feature matrix for all candidate users in a recommendation
  cohort, then calls the scoring server to run model inference and obtain
  ranked scores for downstream item selection.
  """
  def extract_and_forward(scoring_pid, model_id) do
    Logger.info("FeatureExtractor: building feature matrix for model=#{model_id}")

    feature_matrix = build_feature_matrix()

    Logger.info("FeatureExtractor: #{length(feature_matrix)} vectors (dim=#{@feature_dim}) — calling scorer")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the full feature matrix — up to
    # 50 000 user feature vectors, each a list of 512 floats plus metadata —
    # is deep-copied into the ScoringServer heap as the argument of a
    # synchronous GenServer.call. The copy of ~50 000 × 512 floats of data
    # blocks the extractor process for the entire copy duration, adding
    # substantial latency to what is meant to be a real-time scoring pipeline.
    result = GenServer.call(scoring_pid, {:score_batch, model_id, feature_matrix}, :infinity)
    # VALIDATION: SMELL END

    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate building a large feature matrix
  # ---------------------------------------------------------------------------

  defp build_feature_matrix do
    Enum.map(1..50_000, fn n ->
      user_id = "USR-#{String.pad_leading(Integer.to_string(n), 8, "0")}"

      %{
        user_id: user_id,
        vector: build_vector(),
        context: %{
          platform: Enum.random([:web, :ios, :android]),
          hour_of_day: :rand.uniform(24) - 1,
          day_of_week: :rand.uniform(7),
          country_code: Enum.random(["US", "GB", "BR", "IN", "DE"]),
          session_depth: :rand.uniform(20)
        },
        computed_at: DateTime.utc_now()
      }
    end)
  end

  defp build_vector do
    Enum.map(1..@feature_dim, fn _ ->
      (:rand.uniform() - 0.5) * 2.0
    end)
  end
end
```
