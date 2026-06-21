```elixir
defmodule Messaging.Envelope do
  @moduledoc """
  A typed wrapper carrying a domain message alongside routing and
  observability metadata.

  Wrapping messages in envelopes decouples transport concerns (tracing,
  retry counts, deadlines) from domain payload design. Consumers unwrap
  the payload via `payload/1`; infrastructure layers inspect metadata
  without touching domain code.
  """

  @type t(payload) :: %__MODULE__{
          id: String.t(),
          payload: payload,
          topic: String.t(),
          trace_id: String.t(),
          correlation_id: String.t() | nil,
          attempt: non_neg_integer(),
          created_at: integer(),
          deadline_at: integer() | nil,
          headers: %{String.t() => String.t()}
        }

  defstruct [
    :id,
    :payload,
    :topic,
    :trace_id,
    :correlation_id,
    :created_at,
    :deadline_at,
    attempt: 0,
    headers: %{}
  ]

  @spec wrap(term(), String.t(), keyword()) :: t(term())
  def wrap(payload, topic, opts \\ []) when is_binary(topic) do
    now = System.system_time(:millisecond)
    ttl_ms = Keyword.get(opts, :ttl_ms, nil)

    %__MODULE__{
      id: generate_id(),
      payload: payload,
      topic: topic,
      trace_id: Keyword.get(opts, :trace_id, generate_id()),
      correlation_id: Keyword.get(opts, :correlation_id),
      created_at: now,
      deadline_at: if(ttl_ms, do: now + ttl_ms, else: nil),
      headers: Keyword.get(opts, :headers, %{})
    }
  end

  @spec payload(t(payload)) :: payload when payload: term()
  def payload(%__MODULE__{payload: p}), do: p

  @spec expired?(t(term())) :: boolean()
  def expired?(%__MODULE__{deadline_at: nil}), do: false
  def expired?(%__MODULE__{deadline_at: deadline}) do
    System.system_time(:millisecond) > deadline
  end

  @spec increment_attempt(t(term())) :: t(term())
  def increment_attempt(%__MODULE__{} = envelope) do
    %{envelope | attempt: envelope.attempt + 1}
  end

  @spec with_header(t(term()), String.t(), String.t()) :: t(term())
  def with_header(%__MODULE__{} = envelope, key, value)
      when is_binary(key) and is_binary(value) do
    %{envelope | headers: Map.put(envelope.headers, key, value)}
  end

  @spec propagate_tracing(t(term()), t(term())) :: t(term())
  def propagate_tracing(%__MODULE__{} = child, %__MODULE__{} = parent) do
    %{child | trace_id: parent.trace_id, correlation_id: parent.id}
  end

  @spec age_ms(t(term())) :: non_neg_integer()
  def age_ms(%__MODULE__{created_at: created}) do
    System.system_time(:millisecond) - created
  end

  @spec loggable(t(term())) :: map()
  def loggable(%__MODULE__{} = e) do
    %{
      envelope_id: e.id,
      topic: e.topic,
      trace_id: e.trace_id,
      correlation_id: e.correlation_id,
      attempt: e.attempt,
      age_ms: age_ms(e)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
