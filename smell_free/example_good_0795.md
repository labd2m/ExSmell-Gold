```elixir
defmodule Lending.LoanAggregate do
  @moduledoc """
  An event-sourced aggregate representing a loan lifecycle. State is never
  stored directly; only immutable domain events are persisted. The current
  state is reconstituted by replaying events through `apply_event/2`.
  Commands validate business rules against the current state before producing
  events, ensuring invariants are enforced regardless of how state is built.
  """

  alias Lending.LoanAggregate.Events.{
    LoanIssued,
    PaymentReceived,
    LoanClosed,
    LoanDefaulted
  }

  @type status :: :pending | :active | :closed | :defaulted
  @type t :: %__MODULE__{
          id: binary(),
          borrower_id: binary(),
          principal_cents: pos_integer(),
          outstanding_cents: non_neg_integer(),
          interest_rate_bps: pos_integer(),
          status: status(),
          issued_at: DateTime.t() | nil,
          version: non_neg_integer()
        }

  defstruct id: nil,
            borrower_id: nil,
            principal_cents: 0,
            outstanding_cents: 0,
            interest_rate_bps: 0,
            status: :pending,
            issued_at: nil,
            version: 0

  # ---------------------------------------------------------------------------
  # Commands → Events
  # ---------------------------------------------------------------------------

  @doc """
  Issues the loan. Validates that the loan is in pending state.
  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec issue(t(), DateTime.t()) :: {:ok, LoanIssued.t()} | {:error, :already_issued}
  def issue(%__MODULE__{status: :pending, id: id, principal_cents: principal}, issued_at) do
    {:ok, %LoanIssued{loan_id: id, principal_cents: principal, issued_at: issued_at}}
  end

  def issue(%__MODULE__{}, _issued_at), do: {:error, :already_issued}

  @doc """
  Records a payment. Validates that the loan is active and the amount
  does not exceed the outstanding balance.
  """
  @spec pay(t(), pos_integer(), DateTime.t()) ::
          {:ok, PaymentReceived.t()} | {:error, :not_active | :overpayment}
  def pay(%__MODULE__{status: :active} = loan, amount_cents, paid_at)
      when is_integer(amount_cents) and amount_cents > 0 do
    if amount_cents > loan.outstanding_cents do
      {:error, :overpayment}
    else
      closing = amount_cents == loan.outstanding_cents

      {:ok, %PaymentReceived{
        loan_id: loan.id,
        amount_cents: amount_cents,
        remaining_cents: loan.outstanding_cents - amount_cents,
        closing_payment: closing,
        paid_at: paid_at
      }}
    end
  end

  def pay(%__MODULE__{}, _amount, _paid_at), do: {:error, :not_active}

  @doc """
  Marks the loan as defaulted. Only valid for active loans past their due date.
  """
  @spec default(t(), DateTime.t()) :: {:ok, LoanDefaulted.t()} | {:error, :not_active}
  def default(%__MODULE__{status: :active} = loan, defaulted_at) do
    {:ok, %LoanDefaulted{
      loan_id: loan.id,
      outstanding_cents: loan.outstanding_cents,
      defaulted_at: defaulted_at
    }}
  end

  def default(%__MODULE__{}, _at), do: {:error, :not_active}

  # ---------------------------------------------------------------------------
  # Event application (state reconstruction)
  # ---------------------------------------------------------------------------

  @doc """
  Applies a persisted event to produce the next aggregate state.
  """
  @spec apply_event(t(), struct()) :: t()
  def apply_event(loan, %LoanIssued{} = e) do
    %{loan | status: :active, outstanding_cents: e.principal_cents,
             issued_at: e.issued_at, version: loan.version + 1}
  end

  def apply_event(loan, %PaymentReceived{closing_payment: true} = e) do
    %{loan | outstanding_cents: 0, status: :closed, version: loan.version + 1}
  end

  def apply_event(loan, %PaymentReceived{} = e) do
    %{loan | outstanding_cents: e.remaining_cents, version: loan.version + 1}
  end

  def apply_event(loan, %LoanDefaulted{}) do
    %{loan | status: :defaulted, version: loan.version + 1}
  end

  @doc """
  Reconstitutes the aggregate from an ordered list of past events.
  """
  @spec load(t(), [struct()]) :: t()
  def load(%__MODULE__{} = initial, events) when is_list(events) do
    Enum.reduce(events, initial, &apply_event(&2, &1))
  end
end

defmodule Lending.LoanAggregate.Events.LoanIssued do
  @moduledoc false
  defstruct [:loan_id, :principal_cents, :issued_at]
end

defmodule Lending.LoanAggregate.Events.PaymentReceived do
  @moduledoc false
  defstruct [:loan_id, :amount_cents, :remaining_cents, :closing_payment, :paid_at]
end

defmodule Lending.LoanAggregate.Events.LoanClosed do
  @moduledoc false
  defstruct [:loan_id, :closed_at]
end

defmodule Lending.LoanAggregate.Events.LoanDefaulted do
  @moduledoc false
  defstruct [:loan_id, :outstanding_cents, :defaulted_at]
end
```
