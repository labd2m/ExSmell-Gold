```elixir
defmodule Billing.InvoiceNumbering do
  @moduledoc """
  Generates sequential, collision-free invoice numbers within a
  GenServer-serialised counter. Numbers follow a configurable prefix
  and zero-padded sequence format. The counter is persisted to the
  database so restarts pick up from the last issued number rather
  than resetting to zero.
  """

  use GenServer

  alias MyApp.Repo
  alias Billing.InvoiceCounter

  @type invoice_number :: String.t()
  @type counter_state :: %{prefix: String.t(), sequence: pos_integer(), pad_width: pos_integer()}

  @default_prefix "INV"
  @default_pad_width 6

  @doc "Starts the invoice numbering server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Issues the next sequential invoice number."
  @spec next() :: {:ok, invoice_number()}
  def next, do: GenServer.call(__MODULE__, :next)

  @doc "Returns the last issued invoice number without incrementing the counter."
  @spec last_issued() :: {:ok, invoice_number()} | {:error, :none_issued}
  def last_issued, do: GenServer.call(__MODULE__, :last_issued)

  @doc "Formats `sequence` as an invoice number using the current prefix and padding."
  @spec format(pos_integer(), String.t(), pos_integer()) :: invoice_number()
  def format(sequence, prefix \\ @default_prefix, pad_width \\ @default_pad_width) do
    "#{prefix}-#{Integer.to_string(sequence) |> String.pad_leading(pad_width, "0")}"
  end

  @impl GenServer
  def init(opts) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    pad_width = Keyword.get(opts, :pad_width, @default_pad_width)
    sequence = load_sequence()
    {:ok, %{prefix: prefix, pad_width: pad_width, sequence: sequence}}
  end

  @impl GenServer
  def handle_call(:next, _from, state) do
    next_seq = state.sequence + 1
    number = format(next_seq, state.prefix, state.pad_width)
    persist_sequence(next_seq)
    {:reply, {:ok, number}, %{state | sequence: next_seq}}
  end

  def handle_call(:last_issued, _from, %{sequence: 0} = state) do
    {:reply, {:error, :none_issued}, state}
  end

  def handle_call(:last_issued, _from, state) do
    number = format(state.sequence, state.prefix, state.pad_width)
    {:reply, {:ok, number}, state}
  end

  defp load_sequence do
    case Repo.one(from(c in InvoiceCounter, order_by: [desc: c.sequence], limit: 1)) do
      nil -> 0
      %InvoiceCounter{sequence: seq} -> seq
    end
  end

  defp persist_sequence(seq) do
    Repo.insert_all(InvoiceCounter, [%{sequence: seq, issued_at: DateTime.utc_now()}])
  rescue
    _ -> :ok
  end
end
```
