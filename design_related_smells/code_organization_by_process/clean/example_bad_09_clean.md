```elixir
defmodule Auth.PasswordPolicy do
  use GenServer

  @moduledoc """
  Evaluates candidate passwords against configurable security policies.
  Used during user registration, password reset, and admin-forced rotation flows.
  """

  @default_policy %{
    min_length: 12,
    max_length: 128,
    require_uppercase: true,
    require_lowercase: true,
    require_digit: true,
    require_special: true,
    special_chars: ~r/[!@#$%^&*()\-_=+\[\]{};:'"\\|,.<>\/?]/,
    disallow_common: true
  }

  @common_fragments ~w(password letmein welcome qwerty 123456 abc123 admin login)



  def start_link(policy_overrides \\ []) do
    policy = Map.merge(@default_policy, Map.new(policy_overrides))
    GenServer.start_link(__MODULE__, policy, name: __MODULE__)
  end

  @doc """
  Returns a full evaluation report for `password` against the active policy.
  """
  def evaluate(pid \\ __MODULE__, password) do
    GenServer.call(pid, {:evaluate, password})
  end

  @doc """
  Returns a numeric strength score between 0 and 100.
  """
  def score(pid \\ __MODULE__, password) do
    GenServer.call(pid, {:score, password})
  end

  @doc """
  Returns `true` if the password satisfies all mandatory rules.
  """
  def meets_policy?(pid \\ __MODULE__, password) do
    GenServer.call(pid, {:meets_policy, password})
  end

  @doc """
  Returns a list of human-readable violation messages.
  """
  def violations(pid \\ __MODULE__, password) do
    GenServer.call(pid, {:violations, password})
  end

  ## GenServer Callbacks

  @impl true
  def init(policy), do: {:ok, policy}

  @impl true
  def handle_call({:evaluate, password}, _from, policy) do
    report = %{
      length: String.length(password),
      has_uppercase: String.match?(password, ~r/[A-Z]/),
      has_lowercase: String.match?(password, ~r/[a-z]/),
      has_digit: String.match?(password, ~r/\d/),
      has_special: String.match?(password, policy.special_chars),
      has_common_fragment: contains_common?(password),
      meets_policy: run_checks(password, policy) == []
    }

    {:reply, report, policy}
  end

  @impl true
  def handle_call({:score, password}, _from, policy) do
    base = min(String.length(password) * 4, 40)
    variety = count_variety(password, policy)
    penalty = if contains_common?(password), do: 20, else: 0
    total = min(base + variety - penalty, 100) |> max(0)
    {:reply, total, policy}
  end

  @impl true
  def handle_call({:meets_policy, password}, _from, policy) do
    {:reply, run_checks(password, policy) == [], policy}
  end

  @impl true
  def handle_call({:violations, password}, _from, policy) do
    {:reply, run_checks(password, policy), policy}
  end

  defp run_checks(password, policy) do
    len = String.length(password)

    [
      if(len < policy.min_length,
        do: "Password must be at least #{policy.min_length} characters",
        else: nil),
      if(len > policy.max_length,
        do: "Password must not exceed #{policy.max_length} characters",
        else: nil),
      if(policy.require_uppercase and not String.match?(password, ~r/[A-Z]/),
        do: "Must contain at least one uppercase letter",
        else: nil),
      if(policy.require_lowercase and not String.match?(password, ~r/[a-z]/),
        do: "Must contain at least one lowercase letter",
        else: nil),
      if(policy.require_digit and not String.match?(password, ~r/\d/),
        do: "Must contain at least one digit",
        else: nil),
      if(policy.require_special and not String.match?(password, policy.special_chars),
        do: "Must contain at least one special character",
        else: nil),
      if(policy.disallow_common and contains_common?(password),
        do: "Password contains a common or easily guessable pattern",
        else: nil)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp contains_common?(password) do
    lower = String.downcase(password)
    Enum.any?(@common_fragments, &String.contains?(lower, &1))
  end

  defp count_variety(password, policy) do
    checks = [
      String.match?(password, ~r/[A-Z]/),
      String.match?(password, ~r/[a-z]/),
      String.match?(password, ~r/\d/),
      String.match?(password, policy.special_chars)
    ]

    Enum.count(checks, & &1) * 15
  end
end
```
