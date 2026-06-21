```elixir
defmodule Retry.Policy do
  @moduledoc """
  Describes how many times to retry an operation and how long to wait
  between successive attempts.

  Policies are plain structs and can be composed or overridden per
  call site. The default exponential policy with jitter is suitable for
  most outbound service calls.
  """

  @type back_off_kind :: :constant | :linear | :exponential

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          back_off: back_off_kind(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          jitter: boolean()
        }

  defstruct [
    max_attempts: 3,
    back_off: :exponential,
    base_delay_ms: 100,
    max_delay_ms: 30_000,
    jitter: true
  ]

  @spec constant(pos_integer(), non_neg_integer()) :: t()
  def constant(max_attempts, delay_ms) do
    %__MODULE__{
      max_attempts: max_attempts,
      back_off: :constant,
      base_delay_ms: delay_ms,
      max_delay_ms: delay_ms,
      jitter: false
    }
  end

  @spec exponential(pos_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def exponential(max_attempts, base_delay_ms, max_delay_ms) do
    %__MODULE__{
      max_attempts: max_attempts,
      back_off: :exponential,
      base_delay_ms: base_delay_ms,
      max_delay_ms: max_delay_ms,
      jitter: true
    }
  end

  @spec delay_for(t(), pos_integer()) :: non_neg_integer()
  def delay_for(%__MODULE__{back_off: :constant, base_delay_ms: d}, _attempt), do: d

  def delay_for(%__MODULE__{back_off: :linear, base_delay_ms: base, max_delay_ms: max, jitter: jitter}, attempt) do
    raw = min(base * attempt, max)
    add_jitter(raw, jitter)
  end

  def delay_for(%__MODULE__{back_off: :exponential, base_delay_ms: base, max_delay_ms: max, jitter: jitter}, attempt) do
    raw = min(trunc(base * :math.pow(2, attempt - 1)), max)
    add_jitter(raw, jitter)
  end

  defp add_jitter(delay, false), do: delay
  defp add_jitter(delay, true), do: delay + :rand.uniform(max(1, div(delay, 4)))
end

defmodule Retry do
  @moduledoc """
  Executes a function with automatic retry according to a `Policy`.

  The function must return `{:ok, result}` to signal success or
  `{:error, reason}` to trigger a retry. After all attempts are
  exhausted the last error is returned. Each failed attempt emits a
  telemetry event so latency and retry counts are observable.
  """

  alias Retry.Policy

  @spec run(Policy.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(%Policy{max_attempts: max_attempts} = policy, fun) when is_function(fun, 0) do
    do_run(policy, fun, 1, max_attempts)
  end

  defp do_run(_policy, fun, attempt, max) when attempt > max do
    case fun.() do
      {:ok, _result} = ok -> ok
      {:error, _reason} = err -> err
    end
  end

  defp do_run(policy, fun, attempt, max) do
    case fun.() do
      {:ok, _result} = ok ->
        ok

      {:error, reason} ->
        emit_retry_event(attempt, reason)
        :timer.sleep(Policy.delay_for(policy, attempt))
        do_run(policy, fun, attempt + 1, max)
    end
  end

  defp emit_retry_event(attempt, reason) do
    :telemetry.execute(
      [:retry, :attempt_failed],
      %{attempt: attempt},
      %{reason: reason}
    )
  end
end
```
