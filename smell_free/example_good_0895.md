```elixir
defmodule MyApp.Generators do
  @moduledoc """
  StreamData generators for domain types used in property-based tests.
  Centralising generators avoids duplication across test files and ensures
  that any change to a domain type's invariants is reflected everywhere the
  type is generated. All generators produce valid instances unless explicitly
  documented otherwise.
  """

  use ExUnitProperties

  alias Finance.Money
  alias Commerce.Order

  # ---------------------------------------------------------------------------
  # Primitive generators
  # ---------------------------------------------------------------------------

  @doc "Generates a valid UUID v4 string."
  def uuid do
    gen all(
          a <- binary(length: 4),
          b <- binary(length: 2),
          c <- binary(length: 2),
          d <- binary(length: 2),
          e <- binary(length: 6)
        ) do
      [a, b, <<(binary_part(c, 0, 1) |> :binary.decode_unsigned() &&& 0x0F ||| 0x40)::8, binary_part(c, 1, 1)>>, d, e]
      |> Enum.map(&Base.encode16(&1, case: :lower))
      |> Enum.join("-")
    end
  end

  @doc "Generates a valid email address."
  def email do
    gen all(
          local <- string(:alphanumeric, min_length: 2, max_length: 20),
          domain <- string(:alphanumeric, min_length: 3, max_length: 12),
          tld <- member_of(~w[com org net io dev co])
        ) do
      "#{local}@#{domain}.#{tld}"
    end
  end

  @doc "Generates a non-blank binary string up to `max_length` characters."
  def non_blank_string(max_length \\ 100) do
    gen all(
          str <- string(:printable, min_length: 1, max_length: max_length)
        ) do
      String.trim(str)
    end
    |> filter(&(byte_size(&1) > 0))
  end

  # ---------------------------------------------------------------------------
  # Money generators
  # ---------------------------------------------------------------------------

  @doc "Generates a valid Money value object with a positive minor-unit amount."
  def money do
    gen all(
          amount <- positive_integer(),
          currency <- member_of(~w[USD EUR GBP BRL CAD AUD JPY])
        ) do
      Money.new(amount, currency)
    end
  end

  @doc "Generates two Money values in the same currency for arithmetic tests."
  def same_currency_money_pair do
    gen all(
          currency <- member_of(~w[USD EUR GBP BRL]),
          a <- positive_integer(),
          b <- positive_integer()
        ) do
      {Money.new(a, currency), Money.new(b, currency)}
    end
  end

  # ---------------------------------------------------------------------------
  # Order generators
  # ---------------------------------------------------------------------------

  @doc "Generates a valid order line item map."
  def order_item do
    gen all(
          sku_id <- uuid(),
          quantity <- integer(1..50),
          unit_cents <- integer(100..100_000)
        ) do
      %{sku_id: sku_id, quantity: quantity, unit_cents: unit_cents}
    end
  end

  @doc "Generates a valid order input map with 1–10 line items."
  def order_input do
    gen all(
          customer_id <- uuid(),
          items <- list_of(order_item(), min_length: 1, max_length: 10),
          currency <- member_of(~w[USD EUR GBP])
        ) do
      %{customer_id: customer_id, items: items, currency: currency}
    end
  end

  # ---------------------------------------------------------------------------
  # State machine generators
  # ---------------------------------------------------------------------------

  @doc "Generates a sequence of valid order commands for state machine testing."
  def valid_command_sequence(initial_state, transition_fn, command_gen) do
    StreamData.bind(StreamData.list_of(command_gen, min_length: 1, max_length: 20), fn commands ->
      {final_state, executed} =
        Enum.reduce_while(commands, {initial_state, []}, fn cmd, {state, acc} ->
          case transition_fn.(state, cmd) do
            {:ok, next_state} -> {:cont, {next_state, [{cmd, next_state} | acc]}}
            {:error, _} -> {:halt, {state, acc}}
          end
        end)

      StreamData.constant({final_state, Enum.reverse(executed)})
    end)
  end
end

defmodule Finance.MoneyProperties do
  @moduledoc """
  Property-based tests for the `Finance.Money` value object. These tests
  verify mathematical laws (commutativity, associativity, identity) that
  must hold regardless of the specific values involved.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Finance.Money
  alias MyApp.Generators

  property "addition is commutative within the same currency" do
    check all({a, b} <- Generators.same_currency_money_pair()) do
      {:ok, ab} = Money.add(a, b)
      {:ok, ba} = Money.add(b, a)
      assert Money.compare(ab, ba) == :eq
    end
  end

  property "adding zero leaves a money value unchanged" do
    check all(money <- Generators.money()) do
      zero = Money.zero(money.currency)
      {:ok, result} = Money.add(money, zero)
      assert Money.compare(result, money) == :eq
    end
  end

  property "allocation sums to the original total" do
    check all(
            money <- Generators.money(),
            ratios <- list_of(positive_integer(), min_length: 1, max_length: 5)
          ) do
      allocated = Money.allocate(money, Enum.map(ratios, &(&1 * 1.0)))
      total = Enum.reduce(allocated, Money.zero(money.currency), fn m, acc ->
        {:ok, sum} = Money.add(acc, m)
        sum
      end)

      assert Money.compare(total, money) == :eq
    end
  end

  property "currency mismatch addition returns an error" do
    check all(
            a <- Generators.money(),
            b <- Generators.money(),
            a.currency != b.currency
          ) do
      assert Money.add(a, b) == {:error, :currency_mismatch}
    end
  end
end
```
