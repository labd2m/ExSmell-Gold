```elixir
defmodule Retry.Policy do
  @moduledoc """
  Defines retry behaviour for fallible operations: maximum attempts,
  backoff strategy, and which error reasons are retryable.
  Policies are immutable value objects constructed through `new/1`.
  """

  @type backoff :: :constant | :linear | :exponential
  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          backoff: backoff(),
          retryable_reasons: list(atom()) | :all,
          jitter: boolean()
        }

  defstruct max_attempts: 3,
            base_delay_ms: 500,
            max_delay_ms: 30_000,
            backoff: :exponential,
            retryable_reasons: :all,
            jitter: true

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(opts \\ []) do
    policy = struct(__MODULE__, opts)

    cond do
      not (is_integer(policy.max_attempts) and policy.max_attempts > 0) ->
        {:error, :invalid_policy}

      not (is_integer(policy.base_delay_ms) and policy.base_delay_ms > 0) ->
        {:error, :invalid_policy}

      policy.backoff not in [:constant, :linear, :exponential] ->
        {:error, :invalid_policy}

      true ->
        {:ok, policy}
    end
  end

  @spec delay_for_attempt(t(), non_neg_integer()) :: pos_integer()
  def delay_for_attempt(%__MODULE__{} = policy, attempt) when is_integer(attempt) and attempt >= 0 do
    raw_delay = compute_raw_delay(policy, attempt)
    capped = min(raw_delay, policy.max_delay_ms)
    if policy.jitter, do: jitter(capped), else: capped
  end

  @spec retryable?(t(), atom()) :: boolean()
  def retryable?(%__MODULE__{retryable_reasons: :all}, _reason), do: true

  def retryable?(%__MODULE__{retryable_reasons: reasons}, reason) when is_list(reasons) do
    reason in reasons
  end

  defp compute_raw_delay(%{backoff: :constant, base_delay_ms: base}, _attempt), do: base
  defp compute_raw_delay(%{backoff: :linear, base_delay_ms: base}, attempt), do: base * (attempt + 1)
  defp compute_raw_delay(%{backoff: :exponential, base_delay_ms: base}, attempt) do
    trunc(base * :math.pow(2, attempt))
  end

  defp jitter(delay) do
    spread = trunc(delay * 0.2)
    delay + :rand.uniform(max(1, spread)) - trunc(spread / 2)
  end
end

defmodule Retry.Runner do
  @moduledoc """
  Executes a zero-arity function under a given `Retry.Policy`, sleeping
  between attempts and respecting the configured retryable reason list.
  Returns the final outcome along with attempt metadata.
  """

  require Logger

  alias Retry.Policy

  @type attempt_log :: %{attempt: pos_integer(), reason: term(), delay_ms: pos_integer()}
  @type run_result :: {:ok, term(), list(attempt_log())} | {:error, term(), list(attempt_log())}

  @spec run(Policy.t(), (-> {:ok, term()} | {:error, atom()})) :: run_result()
  def run(%Policy{max_attempts: max} = policy, fun) when is_function(fun, 0) do
    do_run(policy, fun, 1, max, [])
  end

  defp do_run(policy, fun, attempt, max, log) do
    case fun.() do
      {:ok, value} ->
        {:ok, value, Enum.reverse(log)}

      {:error, reason} when attempt >= max ->
        {:error, reason, Enum.reverse(log)}

      {:error, reason} ->
        if Policy.retryable?(policy, reason) do
          delay = Policy.delay_for_attempt(policy, attempt - 1)
          entry = %{attempt: attempt, reason: reason, delay_ms: delay}
          Logger.debug("Retrying operation", attempt: attempt, reason: reason, delay_ms: delay)
          Process.sleep(delay)
          do_run(policy, fun, attempt + 1, max, [entry | log])
        else
          {:error, reason, Enum.reverse(log)}
        end
    end
  end
end
```
