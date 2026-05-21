# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Finance.LoanCalculator` module
- **Affected function(s)**: `monthly_payment/2`, `amortization_schedule/2`, `total_interest/2`, `payoff_date/2`
- **Short explanation**: Loan amortization is entirely deterministic mathematics based on principal, rate, and term—no external state, no I/O, no concurrency requirement. The `GenServer` holds an empty state map and never mutates it. Users requesting loan quotes or viewing repayment schedules all serialize through this one process, unnecessarily limiting throughput in what should be a fully parallel computation.

## Code

```elixir
defmodule Finance.LoanCalculator do
  use GenServer

  @moduledoc """
  Computes loan repayment schedules, monthly installments, and interest summaries
  for personal, auto, and mortgage loan products.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because LoanCalculator uses a GenServer to host
  # VALIDATION: pure financial math. The state is never populated or read. Loan
  # VALIDATION: amortization depends only on the three input parameters (principal,
  # VALIDATION: annual_rate, term_months) and produces the same result every time.
  # VALIDATION: A loan comparison tool querying dozens of scenarios in parallel
  # VALIDATION: would serialize every calculation through this one process,
  # VALIDATION: creating a bottleneck with no architectural justification.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the fixed monthly payment for a loan.
  `params` must include `:principal`, `:annual_rate`, `:term_months`.
  """
  def monthly_payment(pid, params) do
    GenServer.call(pid, {:monthly_payment, params})
  end

  @doc """
  Returns the full amortization schedule as a list of monthly maps.
  """
  def amortization_schedule(pid, params) do
    GenServer.call(pid, {:amortization_schedule, params})
  end

  @doc """
  Returns the total interest paid over the life of the loan.
  """
  def total_interest(pid, params) do
    GenServer.call(pid, {:total_interest, params})
  end

  @doc """
  Returns the estimated payoff date given a start date and loan parameters.
  """
  def payoff_date(pid, params, start_date \\ Date.utc_today()) do
    GenServer.call(pid, {:payoff_date, params, start_date})
  end

  @doc """
  Returns a high-level loan summary map.
  """
  def summary(pid, params, start_date \\ Date.utc_today()) do
    GenServer.call(pid, {:summary, params, start_date})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:monthly_payment, params}, _from, state) do
    {:reply, {:ok, compute_monthly_payment(params)}, state}
  end

  @impl true
  def handle_call({:amortization_schedule, params}, _from, state) do
    schedule = build_schedule(params)
    {:reply, {:ok, schedule}, state}
  end

  @impl true
  def handle_call({:total_interest, params}, _from, state) do
    payment = compute_monthly_payment(params)
    total_paid = payment * params.term_months
    interest = Float.round(total_paid - params.principal, 2)
    {:reply, {:ok, interest}, state}
  end

  @impl true
  def handle_call({:payoff_date, params, start_date}, _from, state) do
    payoff = Date.add(start_date, params.term_months * 30)
    {:reply, {:ok, payoff}, state}
  end

  @impl true
  def handle_call({:summary, params, start_date}, _from, state) do
    payment = compute_monthly_payment(params)
    total_paid = Float.round(payment * params.term_months, 2)
    interest = Float.round(total_paid - params.principal, 2)
    payoff = Date.add(start_date, params.term_months * 30)

    result = %{
      principal: params.principal,
      annual_rate: params.annual_rate,
      term_months: params.term_months,
      monthly_payment: payment,
      total_paid: total_paid,
      total_interest: interest,
      interest_ratio: Float.round(interest / total_paid, 4),
      payoff_date: payoff
    }

    {:reply, {:ok, result}, state}
  end

  # VALIDATION: SMELL END

  defp compute_monthly_payment(%{principal: p, annual_rate: r, term_months: n}) do
    monthly_rate = r / 12.0

    if monthly_rate == 0.0 do
      Float.round(p / n, 2)
    else
      factor = :math.pow(1 + monthly_rate, n)
      payment = p * (monthly_rate * factor) / (factor - 1)
      Float.round(payment, 2)
    end
  end

  defp build_schedule(params) do
    %{principal: principal, annual_rate: annual_rate, term_months: term} = params
    monthly_rate = annual_rate / 12.0
    payment = compute_monthly_payment(params)

    {schedule, _} =
      Enum.map_reduce(1..term, principal, fn month, balance ->
        interest_charge = Float.round(balance * monthly_rate, 2)
        principal_charge = Float.round(payment - interest_charge, 2)
        new_balance = Float.round(balance - principal_charge, 2)

        row = %{
          month: month,
          payment: payment,
          principal: principal_charge,
          interest: interest_charge,
          balance: max(new_balance, 0.0)
        }

        {row, new_balance}
      end)

    schedule
  end
end
```
