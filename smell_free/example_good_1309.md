**File:** `example_good_1309.md`

```elixir
defmodule Tracing.Span do
  @moduledoc "Represents a single unit of traced work with timing and metadata."

  @enforce_keys [:id, :name, :trace_id, :started_at]
  defstruct [
    :id,
    :name,
    :trace_id,
    :parent_id,
    :started_at,
    :finished_at,
    :status,
    tags: %{},
    events: []
  ]

  @type status :: :ok | :error | nil
  @type event :: %{name: String.t(), occurred_at: integer(), attrs: map()}
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          trace_id: String.t(),
          parent_id: String.t() | nil,
          started_at: integer(),
          finished_at: integer() | nil,
          status: status(),
          tags: map(),
          events: [event()]
        }

  @spec start(String.t(), String.t(), keyword()) :: t()
  def start(name, trace_id, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      name: name,
      trace_id: trace_id,
      parent_id: Keyword.get(opts, :parent_id),
      started_at: System.monotonic_time(:microsecond),
      status: nil,
      tags: Keyword.get(opts, :tags, %{}),
      events: []
    }
  end

  @spec finish(t(), status()) :: t()
  def finish(%__MODULE__{} = span, status \\ :ok) do
    %{span | finished_at: System.monotonic_time(:microsecond), status: status}
  end

  @spec add_tag(t(), atom() | String.t(), term()) :: t()
  def add_tag(%__MODULE__{tags: tags} = span, key, value) do
    %{span | tags: Map.put(tags, key, value)}
  end

  @spec add_event(t(), String.t(), map()) :: t()
  def add_event(%__MODULE__{events: events} = span, name, attrs \\ %{}) do
    event = %{name: name, occurred_at: System.monotonic_time(:microsecond), attrs: attrs}
    %{span | events: [event | events]}
  end

  @spec duration_us(t()) :: non_neg_integer() | nil
  def duration_us(%__MODULE__{started_at: s, finished_at: f}) when not is_nil(f), do: f - s
  def duration_us(%__MODULE__{}), do: nil

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end

defmodule Tracing.Tracer do
  @moduledoc """
  Provides a process-local span stack for nested tracing.
  Uses the process dictionary to hold the active span context without
  threading it explicitly through every function.
  """

  alias Tracing.Span

  @context_key :__tracing_context__

  @spec current_trace_id() :: String.t() | nil
  def current_trace_id do
    case Process.get(@context_key) do
      %{trace_id: id} -> id
      _ -> nil
    end
  end

  @spec current_span_id() :: String.t() | nil
  def current_span_id do
    case Process.get(@context_key) do
      %{span_stack: [%Span{id: id} | _]} -> id
      _ -> nil
    end
  end

  @spec with_span(String.t(), (-> term())) :: term()
  def with_span(name, func) when is_binary(name) and is_function(func, 0) do
    context = Process.get(@context_key, %{trace_id: generate_trace_id(), span_stack: []})
    parent_id = List.first(context.span_stack) |> then(fn
      %Span{id: id} -> id
      nil -> nil
    end)

    span = Span.start(name, context.trace_id, parent_id: parent_id)
    Process.put(@context_key, %{context | span_stack: [span | context.span_stack]})

    try do
      result = func.()
      finish_span(:ok)
      result
    rescue
      exception ->
        finish_span(:error)
        reraise exception, __STACKTRACE__
    end
  end

  defp finish_span(status) do
    case Process.get(@context_key) do
      %{span_stack: [active | rest]} = ctx ->
        finished = Span.finish(active, status)
        export_span(finished)
        Process.put(@context_key, %{ctx | span_stack: rest})

      _ ->
        :ok
    end
  end

  defp export_span(span) do
    if exporter = Application.get_env(:my_app, :span_exporter) do
      exporter.export(span)
    end
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
