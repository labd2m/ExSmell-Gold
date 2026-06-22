```elixir
defmodule Tracing.ContextPropagator do
  @moduledoc """
  Injects and extracts W3C TraceContext headers for distributed tracing.
  Provides helpers for propagating trace context across HTTP boundaries
  and storing the active span context in the process dictionary.
  """

  @traceparent_header "traceparent"
  @tracestate_header "tracestate"
  @traceparent_version "00"

  @type trace_id :: String.t()
  @type span_id :: String.t()
  @type trace_flags :: non_neg_integer()

  @type span_context :: %{
          trace_id: trace_id(),
          span_id: span_id(),
          trace_flags: trace_flags(),
          tracestate: String.t()
        }

  @spec new_root_context() :: span_context()
  def new_root_context do
    %{
      trace_id: generate_trace_id(),
      span_id: generate_span_id(),
      trace_flags: 1,
      tracestate: ""
    }
  end

  @spec child_context(span_context()) :: span_context()
  def child_context(%{trace_id: trace_id, trace_flags: flags, tracestate: ts}) do
    %{
      trace_id: trace_id,
      span_id: generate_span_id(),
      trace_flags: flags,
      tracestate: ts
    }
  end

  @spec inject_headers(span_context()) :: [{String.t(), String.t()}]
  def inject_headers(%{trace_id: tid, span_id: sid, trace_flags: flags, tracestate: ts}) do
    traceparent = "#{@traceparent_version}-#{tid}-#{sid}-#{format_flags(flags)}"
    headers = [{@traceparent_header, traceparent}]

    if ts != "" do
      [{@tracestate_header, ts} | headers]
    else
      headers
    end
  end

  @spec extract_context([{String.t(), String.t()}]) ::
          {:ok, span_context()} | {:error, :missing_context | :invalid_context}
  def extract_context(headers) when is_list(headers) do
    header_map = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)

    case Map.fetch(header_map, @traceparent_header) do
      :error -> {:error, :missing_context}
      {:ok, traceparent} -> parse_traceparent(traceparent, Map.get(header_map, @tracestate_header, ""))
    end
  end

  @spec put_current(span_context()) :: :ok
  def put_current(context) do
    Process.put(:trace_context, context)
    :ok
  end

  @spec current() :: {:ok, span_context()} | {:error, :no_context}
  def current do
    case Process.get(:trace_context) do
      nil -> {:error, :no_context}
      ctx -> {:ok, ctx}
    end
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(:trace_context)
    :ok
  end

  @spec with_context(span_context(), (-> result)) :: result when result: term()
  def with_context(context, fun) when is_function(fun, 0) do
    put_current(context)

    try do
      fun.()
    after
      clear()
    end
  end

  @spec parse_traceparent(String.t(), String.t()) ::
          {:ok, span_context()} | {:error, :invalid_context}
  defp parse_traceparent(traceparent, tracestate) do
    case String.split(traceparent, "-") do
      [_version, trace_id, span_id, flags_str]
      when byte_size(trace_id) == 32 and byte_size(span_id) == 16 ->
        case Integer.parse(flags_str, 16) do
          {flags, ""} ->
            {:ok, %{trace_id: trace_id, span_id: span_id, trace_flags: flags, tracestate: tracestate}}
          _ ->
            {:error, :invalid_context}
        end
      _ ->
        {:error, :invalid_context}
    end
  end

  @spec generate_trace_id() :: trace_id()
  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @spec generate_span_id() :: span_id()
  defp generate_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec format_flags(trace_flags()) :: String.t()
  defp format_flags(flags) do
    flags |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
  end
end
```
