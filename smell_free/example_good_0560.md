```elixir
defmodule Bff.UpstreamCall do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          fun: (-> {:ok, term()} | {:error, term()}),
          required: boolean(),
          default: term()
        }

  defstruct [:name, :fun, required: true, default: nil]

  @spec new(atom(), (-> {:ok, term()} | {:error, term()}), keyword()) :: t()
  def new(name, fun, opts \\ []) when is_atom(name) and is_function(fun, 0) do
    %__MODULE__{
      name: name,
      fun: fun,
      required: Keyword.get(opts, :required, true),
      default: Keyword.get(opts, :default, nil)
    }
  end
end

defmodule Bff.AggregatorResult do
  @moduledoc false

  @type t :: %__MODULE__{
          data: map(),
          errors: %{atom() => term()},
          partial: boolean()
        }

  defstruct [data: %{}, errors: %{}, partial: false]
end

defmodule Bff.Aggregator do
  @moduledoc """
  Executes multiple upstream API calls concurrently and merges their results
  into a single response map suitable for a client-facing endpoint.

  Required calls that fail abort the aggregation and return an error.
  Optional calls that fail substitute their declared default value and set
  the `partial` flag so clients know the response may be incomplete.
  All calls run concurrently, so total latency is bounded by the slowest
  required upstream rather than the sum of all latencies.
  """

  alias Bff.{AggregatorResult, UpstreamCall}

  @type opts :: [timeout_ms: pos_integer(), supervisor: atom()]

  @spec aggregate([UpstreamCall.t()], opts()) ::
          {:ok, AggregatorResult.t()} | {:error, {atom(), term()}}
  def aggregate(calls, opts \\ []) when is_list(calls) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    supervisor = Keyword.get(opts, :supervisor, Bff.TaskSupervisor)

    raw_results =
      calls
      |> Task.Supervisor.async_stream_nolink(supervisor, fn call ->
        {call.name, call.required, call.default, call.fun.()}
      end, timeout: timeout, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:unknown, true, nil, {:error, {:exit, reason}}}
      end)

    build_result(raw_results)
  end

  defp build_result(raw_results) do
    Enum.reduce_while(raw_results, {:ok, %AggregatorResult{}}, fn
      {name, true, _default, {:error, reason}}, _acc ->
        {:halt, {:error, {name, reason}}}

      {name, false, default, {:error, reason}}, {:ok, acc} ->
        updated = %{acc |
          data: Map.put(acc.data, name, default),
          errors: Map.put(acc.errors, name, reason),
          partial: true
        }
        {:cont, {:ok, updated}}

      {name, _required, _default, {:ok, value}}, {:ok, acc} ->
        {:cont, {:ok, %{acc | data: Map.put(acc.data, name, value)}}}
    end)
  end
end
```
