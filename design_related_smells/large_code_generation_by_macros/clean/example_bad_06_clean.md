```elixir
defmodule Inventory.OperationDSL do
  @moduledoc """
  Compile-time DSL for declaring inventory operations.

  Operations represent stock movements (receipts, issues, adjustments,
  transfers) with their unit types, ledger bindings, and approval rules.
  Each operation is validated and registered at compile time.
  """

  @valid_directions [:inbound, :outbound, :neutral]
  @valid_unit_types [:unit, :kg, :litre, :box, :pallet]

  defmacro defoperation(op_name, opts) do
    quote do
      op   = unquote(op_name)
      opts = unquote(opts)

      unless is_atom(op) do
        raise ArgumentError,
              "operation name must be an atom, got: #{inspect(op)}"
      end

      label = Keyword.fetch!(opts, :label)

      unless is_binary(label) do
        raise ArgumentError,
              "operation #{inspect(op)} :label must be a binary"
      end

      direction = Keyword.fetch!(opts, :direction)

      unless direction in unquote(@valid_directions) do
        raise ArgumentError,
              "operation #{inspect(op)} :direction must be one of #{inspect(unquote(@valid_directions))}"
      end

      unit_type = Keyword.get(opts, :unit_type, :unit)

      unless unit_type in unquote(@valid_unit_types) do
        raise ArgumentError,
              "operation #{inspect(op)} :unit_type must be one of #{inspect(unquote(@valid_unit_types))}"
      end

      ledger_account = Keyword.fetch!(opts, :ledger_account)

      unless is_binary(ledger_account) do
        raise ArgumentError,
              "operation #{inspect(op)} :ledger_account must be a binary account code"
      end

      requires_approval_above = Keyword.get(opts, :requires_approval_above)

      if requires_approval_above != nil do
        unless is_number(requires_approval_above) and requires_approval_above >= 0 do
          raise ArgumentError,
                "operation #{inspect(op)} :requires_approval_above must be a non-negative number"
        end
      end

      reversible = Keyword.get(opts, :reversible, true)

      unless is_boolean(reversible) do
        raise ArgumentError,
              "operation #{inspect(op)} :reversible must be a boolean"
      end

      track_serial = Keyword.get(opts, :track_serial, false)

      unless is_boolean(track_serial) do
        raise ArgumentError,
              "operation #{inspect(op)} :track_serial must be a boolean"
      end

      @inventory_operations %{
        name:                    op,
        label:                   label,
        direction:               direction,
        unit_type:               unit_type,
        ledger_account:          ledger_account,
        requires_approval_above: requires_approval_above,
        reversible:              reversible,
        track_serial:            track_serial
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Inventory.OperationDSL, only: [defoperation: 2]
      Module.register_attribute(__MODULE__, :inventory_operations, accumulate: true)
      @before_compile Inventory.OperationDSL
    end
  end

  defmacro __before_compile__(env) do
    ops = Module.get_attribute(env.module, :inventory_operations)

    quote do
      def operations, do: unquote(Macro.escape(ops))

      def operation(name) do
        Enum.find(operations(), &(&1.name == name))
      end

      def needs_approval?(op_name, quantity) do
        case operation(op_name) do
          nil -> false
          op  -> op.requires_approval_above != nil and quantity > op.requires_approval_above
        end
      end
    end
  end
end

defmodule Inventory.WarehouseOperations do
  use Inventory.OperationDSL

  defoperation(:goods_receipt,
    label: "Goods Receipt",
    direction: :inbound,
    unit_type: :unit,
    ledger_account: "1300",
    requires_approval_above: nil,
    reversible: true,
    track_serial: true
  )

  defoperation(:sales_issue,
    label: "Sales Issue",
    direction: :outbound,
    unit_type: :unit,
    ledger_account: "5000",
    requires_approval_above: 500,
    reversible: true,
    track_serial: true
  )

  defoperation(:write_off,
    label: "Inventory Write-off",
    direction: :outbound,
    unit_type: :unit,
    ledger_account: "6100",
    requires_approval_above: 100,
    reversible: false,
    track_serial: false
  )

  defoperation(:stock_adjustment,
    label: "Stock Adjustment",
    direction: :neutral,
    unit_type: :unit,
    ledger_account: "1301",
    requires_approval_above: 50,
    reversible: false,
    track_serial: false
  )

  defoperation(:interwarehouse_transfer,
    label: "Inter-warehouse Transfer",
    direction: :neutral,
    unit_type: :pallet,
    ledger_account: "1302",
    requires_approval_above: 200,
    reversible: true,
    track_serial: true
  )

  defoperation(:return_from_customer,
    label: "Customer Return",
    direction: :inbound,
    unit_type: :unit,
    ledger_account: "1303",
    requires_approval_above: nil,
    reversible: false,
    track_serial: true
  )
end
```
