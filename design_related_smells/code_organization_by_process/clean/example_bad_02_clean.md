```elixir
defmodule Auth.PasswordPolicy do
  use GenServer

  @moduledoc """
  Enforces password strength policies during user registration and
  password-change flows. All rules are configurable at startup via
  the `policy` option map.
  """

  @default_policy %{
    min_length: 10,
    require_uppercase: true,
    require_digit: true,
    require_special: true,
    disallow_spaces: true,
    special_chars: ~r/[!@#$%^&*()\-_=+\[\]{};:'",.<>?\/\\|`~]/
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {policy, gen_opts} = Keyword.pop(opts, :policy, @default_policy)
    GenServer.start_link(__MODULE__, policy, gen_opts)
  end




  @doc """
  Validates a plaintext password against the configured policy.
  Returns `{:ok, :valid}` or `{:error, reasons}` where `reasons` is a list
  of human-readable violation strings.
  """
  def validate(pid, password) do
    GenServer.call(pid, {:validate, password})
  end

  @doc """
  Returns an integer strength score from 0 to 100.
  """
  def strength_score(pid, password) do
    GenServer.call(pid, {:strength_score, password})
  end

  @doc "Returns true if the password meets the configured minimum length."
  def meets_minimum_length?(pid, password) do
    GenServer.call(pid, {:meets_minimum_length?, password})
  end

  @doc "Returns true if the password contains at least one special character."
  def has_special_char?(pid, password) do
    GenServer.call(pid, {:has_special_char?, password})
  end

  @doc "Returns true if the password contains at least one numeric digit."
  def has_digit?(pid, password) do
    GenServer.call(pid, {:has_digit?, password})
  end
  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(policy), do: {:ok, policy}

  @impl true
  def handle_call({:validate, password}, _from, policy) do
    violations = collect_violations(password, policy)
    result = if violations == [], do: {:ok, :valid}, else: {:error, violations}
    {:reply, result, policy}
  end

  @impl true
  def handle_call({:strength_score, password}, _from, policy) do
    score = calculate_score(password, policy)
    {:reply, score, policy}
  end

  @impl true
  def handle_call({:meets_minimum_length?, password}, _from, policy) do
    {:reply, String.length(password) >= policy.min_length, policy}
  end

  @impl true
  def handle_call({:has_special_char?, password}, _from, policy) do
    {:reply, Regex.match?(policy.special_chars, password), policy}
  end

  @impl true
  def handle_call({:has_digit?, password}, _from, policy) do
    {:reply, Regex.match?(~r/\d/, password), policy}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp collect_violations(password, policy) do
    []
    |> maybe_add(String.length(password) < policy.min_length,
        "must be at least #{policy.min_length} characters")
    |> maybe_add(policy.require_uppercase && !Regex.match?(~r/[A-Z]/, password),
        "must contain at least one uppercase letter")
    |> maybe_add(policy.require_digit && !Regex.match?(~r/\d/, password),
        "must contain at least one digit")
    |> maybe_add(policy.require_special && !Regex.match?(policy.special_chars, password),
        "must contain at least one special character")
    |> maybe_add(policy.disallow_spaces && String.contains?(password, " "),
        "must not contain spaces")
  end

  defp maybe_add(list, true, msg), do: [msg | list]
  defp maybe_add(list, false, _msg), do: list

  defp calculate_score(password, policy) do
    len = String.length(password)
    base = min(len * 4, 40)
    upper = if Regex.match?(~r/[A-Z]/, password), do: 10, else: 0
    digit = if Regex.match?(~r/\d/, password), do: 10, else: 0
    special = if Regex.match?(policy.special_chars, password), do: 20, else: 0
    variety = if Regex.match?(~r/[a-z]/, password), do: 10, else: 0
    excess = max(0, (len - policy.min_length) * 1)
    min(base + upper + digit + special + variety + excess, 100)
  end
end
```
