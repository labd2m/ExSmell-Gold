```elixir
defmodule Jobs.RetryPolicy do
  @moduledoc """
  Encapsulates retry behaviour for background jobs. Each policy definition
  specifies the maximum attempt count, the backoff strategy, and a list of
  error classes that are retryable versus permanently fatal. The module
  exposes a pure `next_attempt/2` function so job runners can determine
  delay and eligibility without coupling to any specific queue library.
  """

  @enforce_keys [:max_attempts, :backoff, :retryable_errors]
  defstruct [:max_attempts, :backoff, :retryable_errors, jitter_ms: 0]

  @type backoff_strategy :: :linear | :exponential | :fixed
  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: {backoff_strategy(), base_ms :: pos_integer()},
          retryable_errors: [atom()],
          jitter_ms: non_neg_integer()
        }

  @type attempt_decision ::
          {:retry, delay_ms :: non_neg_integer()}
          | {:discard, :max_attempts_exceeded}
          | {:discard, :non_retryable_error}

  @doc "Returns the standard retry policy used by most background jobs."
  @spec default() :: t()
  def default do
    %__MODULE__{
      max_attempts: 5,
      backoff: {:exponential, 1_000},
      retryable_errors: [:timeout, :network_error, :rate_limited, :temporary_failure],
      jitter_ms: 500
    }
  end

  @doc "Returns a conservative policy for high-value idempotent jobs."
  @spec conservative() :: t()
  def conservative do
    %__MODULE__{
      max_attempts: 10,
      backoff: {:exponential, 2_000},
      retryable_errors: [:timeout, :network_error, :rate_limited, :temporary_failure, :conflict],
      jitter_ms: 1_000
    }
  end

  @doc """
  Determines the next action for a job after a failure. `attempt` is the
  1-based number of the attempt that just failed. Returns a retry decision
  with the delay or a discard decision with the reason.
  """
  @spec next_attempt(t(), %{attempt: pos_integer(), error: atom()}) :: attempt_decision()
  def next_attempt(%__MODULE__{} = policy, %{attempt: attempt, error: error}) do
    cond do
      error not in policy.retryable_errors ->
        {:discard, :non_retryable_error}

      attempt >= policy.max_attempts ->
        {:discard, :max_attempts_exceeded}

      true ->
        delay = compute_delay(policy, attempt)
        {:retry, delay}
    end
  end

  @doc "Returns the computed delay in milliseconds for the nth retry attempt."
  @spec delay_for(t(), pos_integer()) :: non_neg_integer()
  def delay_for(%__MODULE__{backoff: backoff, jitter_ms: jitter}, attempt) do
    base = raw_delay(backoff, attempt)
    jitter = if jitter > 0, do: :rand.uniform(jitter), else: 0
    base + jitter
  end

  defp compute_delay(policy, attempt), do: delay_for(policy, attempt)

  defp raw_delay({:fixed, base_ms}, _attempt), do: base_ms
  defp raw_delay({:linear, base_ms}, attempt), do: base_ms * attempt
  defp raw_delay({:exponential, base_ms}, attempt) do
    trunc(base_ms * :math.pow(2, attempt - 1))
  end
end
```
