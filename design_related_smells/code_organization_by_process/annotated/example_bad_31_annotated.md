# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `PasswordValidator` module — entire GenServer structure |
| **Affected function(s)** | `validate/2`, `strength_score/2`, `policy_violations/2` |
| **Short explanation** | Password validation is pure computation on a string input against a set of rules. No state is shared between calls, no concurrency is needed, and no I/O occurs. Encoding this logic in a GenServer adds unnecessary serialisation of what could safely run in parallel across many concurrent web requests. |

```elixir
defmodule Auth.PasswordValidator do
  use GenServer

  @moduledoc """
  Validates passwords against configurable policy rules used during
  user registration and password-change flows in the authentication service.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because password validation is a pure,
  # side-effect-free computation. Every call analyses a string against a static
  # policy and returns a result. There is no mutable server state involved.
  # Funnelling all validation requests through a single process needlessly
  # serialises work that could execute concurrently in caller processes.

  @default_policy %{
    min_length: 10,
    max_length: 128,
    require_uppercase: true,
    require_lowercase: true,
    require_digit: true,
    require_special: true,
    special_chars: ~c"!@#$%^&*()-_=+[]{}|;:',.<>?/`~",
    disallow_spaces: true
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Validates `password` against `policy`. Returns `{:ok, :strong}` or
  `{:error, violations}` where `violations` is a list of rule atoms.
  """
  def validate(pid, password, policy \\ @default_policy) do
    GenServer.call(pid, {:validate, password, policy})
  end

  @doc """
  Returns an integer strength score (0–100) for `password`.
  """
  def strength_score(pid, password, policy \\ @default_policy) do
    GenServer.call(pid, {:strength_score, password, policy})
  end

  @doc """
  Returns a list of policy violations for `password`.
  """
  def policy_violations(pid, password, policy \\ @default_policy) do
    GenServer.call(pid, {:policy_violations, password, policy})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:validate, password, policy}, _from, state) do
    violations = compute_violations(password, policy)

    result =
      if violations == [] do
        {:ok, :strong}
      else
        {:error, violations}
      end

    {:reply, result, state}
  end

  def handle_call({:strength_score, password, policy}, _from, state) do
    violations = compute_violations(password, policy)
    total_rules = map_size(policy)
    passed = total_rules - length(violations)
    score = trunc(passed / total_rules * 100)
    {:reply, score, state}
  end

  def handle_call({:policy_violations, password, policy}, _from, state) do
    {:reply, compute_violations(password, policy), state}
  end

  ## Private helpers

  defp compute_violations(password, policy) do
    []
    |> check_min_length(password, policy)
    |> check_max_length(password, policy)
    |> check_uppercase(password, policy)
    |> check_lowercase(password, policy)
    |> check_digit(password, policy)
    |> check_special(password, policy)
    |> check_spaces(password, policy)
  end

  defp check_min_length(acc, pw, %{min_length: min}) do
    if String.length(pw) >= min, do: acc, else: [:too_short | acc]
  end

  defp check_max_length(acc, pw, %{max_length: max}) do
    if String.length(pw) <= max, do: acc, else: [:too_long | acc]
  end

  defp check_uppercase(acc, pw, %{require_uppercase: true}) do
    if String.match?(pw, ~r/[A-Z]/), do: acc, else: [:missing_uppercase | acc]
  end
  defp check_uppercase(acc, _, _), do: acc

  defp check_lowercase(acc, pw, %{require_lowercase: true}) do
    if String.match?(pw, ~r/[a-z]/), do: acc, else: [:missing_lowercase | acc]
  end
  defp check_lowercase(acc, _, _), do: acc

  defp check_digit(acc, pw, %{require_digit: true}) do
    if String.match?(pw, ~r/[0-9]/), do: acc, else: [:missing_digit | acc]
  end
  defp check_digit(acc, _, _), do: acc

  defp check_special(acc, pw, %{require_special: true, special_chars: chars}) do
    pattern = "[#{Regex.escape(to_string(chars))}]"
    if String.match?(pw, ~r/#{pattern}/), do: acc, else: [:missing_special | acc]
  end
  defp check_special(acc, _, _), do: acc

  defp check_spaces(acc, pw, %{disallow_spaces: true}) do
    if String.contains?(pw, " "), do: [:contains_space | acc], else: acc
  end
  defp check_spaces(acc, _, _), do: acc

  # VALIDATION: SMELL END
end
```
