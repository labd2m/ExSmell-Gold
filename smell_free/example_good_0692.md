```elixir
defmodule Monitoring.TraceContext do
  @moduledoc """
  Propagates distributed trace context across process boundaries using
  the W3C Traceparent header format. The context is stored in the process
  dictionary so it is available throughout a request's call stack without
  explicit threading. Child spans inherit the parent trace ID and carry
  their own span ID for correlation.
  """

  @version "00"
  @traceparent_pattern ~r/^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/

  @type trace_id :: String.t()
  @type span_id :: String.t()
  @type trace_flags :: String.t()
  @type trace_context :: %{
          trace_id: trace_id(),
          span_id: span_id(),
          trace_flags: trace_flags(),
          parent_span_id: span_id() | nil
        }

  @doc """
  Extracts and stores the trace context from a `traceparent` header value.
  If the header is absent or malformed, a new root context is generated.
  """
  @spec extract(String.t() | nil) :: trace_context()
  def extract(nil), do: start_root()
  def extract(""), do: start_root()

  def extract(traceparent) when is_binary(traceparent) do
    case Regex.run(@traceparent_pattern, traceparent) do
      [_, trace_id, parent_span_id, flags] ->
        ctx = %{
          trace_id: trace_id,
          span_id: generate_span_id(),
          trace_flags: flags,
          parent_span_id: parent_span_id
        }
        store(ctx)
        ctx

      nil ->
        start_root()
    end
  end

  @doc "Starts a new root trace context with no parent."
  @spec start_root() :: trace_context()
  def start_root do
    ctx = %{
      trace_id: generate_trace_id(),
      span_id: generate_span_id(),
      trace_flags: "01",
      parent_span_id: nil
    }

    store(ctx)
    ctx
  end

  @doc "Returns the current trace context for the calling process."
  @spec current() :: trace_context() | nil
  def current, do: Process.get(:trace_context)

  @doc "Creates a child span from the current context and stores it."
  @spec start_child_span() :: trace_context() | nil
  def start_child_span do
    case current() do
      nil ->
        nil

      parent ->
        child = %{parent | span_id: generate_span_id(), parent_span_id: parent.span_id}
        store(child)
        child
    end
  end

  @doc "Formats the current context as a W3C `traceparent` header value."
  @spec to_header() :: String.t() | nil
  def to_header do
    case current() do
      nil -> nil
      %{trace_id: tid, span_id: sid, trace_flags: flags} ->
        "#{@version}-#{tid}-#{sid}-#{flags}"
    end
  end

  @doc "Clears the trace context from the process dictionary."
  @spec clear() :: :ok
  def clear do
    Process.delete(:trace_context)
    :ok
  end

  @doc "Runs `fun` in a child span, restoring the parent context on return."
  @spec with_child_span((-> result)) :: result when result: var
  def with_child_span(fun) when is_function(fun, 0) do
    parent = current()
    start_child_span()

    try do
      fun.()
    after
      if parent, do: store(parent), else: clear()
    end
  end

  defp store(ctx), do: Process.put(:trace_context, ctx)

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp generate_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
