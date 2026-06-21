```elixir
defmodule Tracing.Span do
  @moduledoc false

  @type t :: %__MODULE__{
          name: String.t(),
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          start_time: integer(),
          attributes: map()
        }

  defstruct [:name, :trace_id, :span_id, :parent_span_id, :start_time, attributes: %{}]
end

defmodule Tracing do
  @moduledoc """
  Lightweight distributed trace span tracking via process dictionary.

  Spans form a parent-child hierarchy within a single process. `with_span/3`
  creates a span, executes the given function, and emits a telemetry stop
  event carrying the span duration and attributes. Nested calls to
  `with_span/3` automatically link child spans to the enclosing parent.
  """

  alias Tracing.Span

  @current_span_key :__tracing_current_span__

  @spec with_span(String.t(), map(), (-> term())) :: term()
  def with_span(name, attributes \\ %{}, fun)
      when is_binary(name) and is_map(attributes) and is_function(fun, 0) do
    span = start_span(name, attributes)

    try do
      result = fun.()
      stop_span(span, %{status: :ok})
      result
    rescue
      error ->
        stop_span(span, %{status: :error, error: inspect(error)})
        reraise error, __STACKTRACE__
    end
  end

  @spec current_trace_id() :: String.t() | nil
  def current_trace_id do
    case Process.get(@current_span_key) do
      nil -> nil
      %Span{trace_id: id} -> id
    end
  end

  @spec current_span_id() :: String.t() | nil
  def current_span_id do
    case Process.get(@current_span_key) do
      nil -> nil
      %Span{span_id: id} -> id
    end
  end

  @spec inject_headers(map()) :: map()
  def inject_headers(headers) when is_map(headers) do
    case Process.get(@current_span_key) do
      nil ->
        headers

      %Span{trace_id: trace_id, span_id: span_id} ->
        headers
        |> Map.put("x-trace-id", trace_id)
        |> Map.put("x-parent-span-id", span_id)
    end
  end

  defp start_span(name, attributes) do
    parent = Process.get(@current_span_key)

    span = %Span{
      name: name,
      trace_id: parent_trace_id(parent),
      span_id: generate_id(),
      parent_span_id: parent && parent.span_id,
      start_time: System.monotonic_time(:microsecond),
      attributes: attributes
    }

    Process.put(@current_span_key, span)

    :telemetry.execute(
      [:tracing, :span, :start],
      %{system_time: System.system_time()},
      %{span: span.name, trace_id: span.trace_id, span_id: span.span_id}
    )

    {span, parent}
  end

  defp stop_span({span, parent_span}, extra_attrs) do
    duration = System.monotonic_time(:microsecond) - span.start_time
    Process.put(@current_span_key, parent_span)

    :telemetry.execute(
      [:tracing, :span, :stop],
      %{duration: duration},
      Map.merge(
        %{span: span.name, trace_id: span.trace_id, span_id: span.span_id,
          parent_span_id: span.parent_span_id},
        extra_attrs
      )
    )
  end

  defp parent_trace_id(nil), do: generate_id()
  defp parent_trace_id(%Span{trace_id: id}), do: id

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
