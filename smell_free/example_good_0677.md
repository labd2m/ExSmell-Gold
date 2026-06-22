```elixir
defmodule Fanout.Endpoint do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          topics: [String.t()],
          secret: String.t() | nil,
          active: boolean()
        }

  defstruct [:id, :url, :topics, :secret, active: true]
end

defmodule Fanout.DispatchResult do
  @moduledoc false

  @type t :: %__MODULE__{
          endpoint_id: String.t(),
          topic: String.t(),
          status: :delivered | :failed,
          http_status: non_neg_integer() | nil,
          error: term() | nil,
          duration_ms: non_neg_integer()
        }

  defstruct [:endpoint_id, :topic, :http_status, :error, :duration_ms, status: :failed]
end

defmodule Fanout.Orchestrator do
  @moduledoc """
  Dispatches a single domain event to all active endpoints that subscribe
  to its topic, concurrently.

  Each delivery is attempted in an isolated supervised Task. Results are
  collected after all tasks complete (or time out) so that a slow endpoint
  does not delay the others. Per-endpoint delivery results are returned for
  caller-side logging or retry scheduling.
  """

  alias Fanout.{DispatchResult, Endpoint}

  @type event :: %{required(:topic) => String.t(), required(:payload) => map()}
  @type opts :: [timeout_ms: pos_integer(), supervisor: atom()]

  @spec dispatch(event(), [Endpoint.t()], opts()) :: [DispatchResult.t()]
  def dispatch(%{topic: topic, payload: payload} = _event, endpoints, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 10_000)
    supervisor = Keyword.get(opts, :supervisor, Fanout.TaskSupervisor)

    active_subscribers = Enum.filter(endpoints, fn ep ->
      ep.active and topic in ep.topics
    end)

    active_subscribers
    |> Task.Supervisor.async_stream_nolink(
      supervisor,
      fn endpoint -> deliver(endpoint, topic, payload) end,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(active_subscribers)
    |> Enum.map(fn {task_result, endpoint} ->
      case task_result do
        {:ok, result} -> result
        {:exit, reason} ->
          %DispatchResult{
            endpoint_id: endpoint.id,
            topic: topic,
            status: :failed,
            error: {:exit, reason},
            duration_ms: timeout
          }
      end
    end)
  end

  defp deliver(%Endpoint{} = endpoint, topic, payload) do
    start = System.monotonic_time(:millisecond)
    body = Jason.encode!(payload)
    headers = build_headers(endpoint, body)

    result =
      case :httpc.request(:post, {to_charlist(endpoint.url), headers,
           ~c"application/json", body}, [timeout: 8_000], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
          %DispatchResult{endpoint_id: endpoint.id, topic: topic,
                          status: :delivered, http_status: status}

        {:ok, {{_, status, _}, _, _}} ->
          %DispatchResult{endpoint_id: endpoint.id, topic: topic,
                          status: :failed, http_status: status}

        {:error, reason} ->
          %DispatchResult{endpoint_id: endpoint.id, topic: topic,
                          status: :failed, error: reason}
      end

    duration = System.monotonic_time(:millisecond) - start
    %{result | duration_ms: duration}
  end

  defp build_headers(%Endpoint{secret: nil}, _body), do: []

  defp build_headers(%Endpoint{secret: secret}, body) do
    sig = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    [{~c"x-webhook-signature", to_charlist("sha256=#{sig}")}]
  end
end
```
