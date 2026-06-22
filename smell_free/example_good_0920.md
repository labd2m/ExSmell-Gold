```elixir
defmodule Tracing.TraceContext do
  @moduledoc """
  Implements the W3C Trace Context specification (Level 1) for distributed
  trace propagation across service boundaries.

  A `traceparent` header carries four fields: version, trace-id, parent-id,
  and trace-flags. This module parses incoming headers, creates child
  contexts for outbound requests (same trace-id, new parent-id), and builds
  the header string for injection. The `tracestate` header is preserved
  opaquely and passed through unchanged.
  """

  @version "00"
  @flag_sampled 0x01

  @type t :: %__MODULE__{
          trace_id: String.t(),
          parent_id: String.t(),
          flags: non_neg_integer(),
          tracestate: String.t() | nil
        }

  defstruct [:trace_id, :parent_id, :tracestate, flags: 0]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_traceparent}
  def parse(header) when is_binary(header) do
    case String.split(header, "-") do
      [@version, trace_id, parent_id, flags_hex]
      when byte_size(trace_id) == 32 and byte_size(parent_id) == 16 ->
        with {:ok, flags} <- parse_flags(flags_hex),
             true <- valid_hex?(trace_id),
             true <- valid_hex?(parent_id),
             false <- all_zeros?(trace_id),
             false <- all_zeros?(parent_id) do
          {:ok, %__MODULE__{trace_id: trace_id, parent_id: parent_id, flags: flags}}
        else
          _ -> {:error, :invalid_traceparent}
        end

      _ ->
        {:error, :invalid_traceparent}
    end
  end

  @spec build(t()) :: String.t()
  def build(%__MODULE__{trace_id: tid, parent_id: pid, flags: flags}) do
    "#{@version}-#{tid}-#{pid}-#{Integer.to_string(flags, 16) |> String.pad_leading(2, "0")}"
  end

  @spec child(t()) :: t()
  def child(%__MODULE__{} = parent) do
    %__MODULE__{
      trace_id: parent.trace_id,
      parent_id: generate_span_id(),
      flags: parent.flags,
      tracestate: parent.tracestate
    }
  end

  @spec new_root() :: t()
  def new_root do
    %__MODULE__{
      trace_id: generate_trace_id(),
      parent_id: generate_span_id(),
      flags: @flag_sampled
    }
  end

  @spec sampled?(t()) :: boolean()
  def sampled?(%__MODULE__{flags: flags}), do: Bitwise.band(flags, @flag_sampled) == @flag_sampled

  @spec with_tracestate(t(), String.t()) :: t()
  def with_tracestate(%__MODULE__{} = ctx, tracestate) when is_binary(tracestate) do
    %{ctx | tracestate: tracestate}
  end

  @spec inject_headers(t(), map()) :: map()
  def inject_headers(%__MODULE__{} = ctx, headers) when is_map(headers) do
    headers = Map.put(headers, "traceparent", build(ctx))
    if ctx.tracestate, do: Map.put(headers, "tracestate", ctx.tracestate), else: headers
  end

  @spec extract_from_headers(map() | [{String.t(), String.t()}]) ::
          {:ok, t()} | {:error, :missing | :invalid_traceparent}
  def extract_from_headers(headers) do
    traceparent = get_header(headers, "traceparent")
    tracestate = get_header(headers, "tracestate")

    case traceparent do
      nil ->
        {:error, :missing}

      value ->
        case parse(value) do
          {:ok, ctx} -> {:ok, with_tracestate(ctx, tracestate)}
          {:error, _} = err -> err
        end
    end
  end

  defp parse_flags(hex) do
    case Integer.parse(hex, 16) do
      {flags, ""} -> {:ok, flags}
      _ -> {:error, :invalid_flags}
    end
  end

  defp valid_hex?(str), do: String.match?(str, ~r/\A[0-9a-f]+\z/)
  defp all_zeros?(str), do: String.replace(str, "0", "") == ""

  defp generate_trace_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp generate_span_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp get_header(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.downcase(key))
  defp get_header(list, key) when is_list(list) do
    Enum.find_value(list, fn {k, v} -> if String.downcase(k) == key, do: v end)
  end
end
```
