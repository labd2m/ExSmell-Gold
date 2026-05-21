# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `UnitConverter` module — entire GenServer structure |
| **Affected function(s)** | `convert/4`, `to_base/3`, `from_base/3`, `compatible?/3` |
| **Short explanation** | Unit conversion is a pure mathematical operation involving a static conversion factor table and arithmetic. No state changes between calls, no I/O occurs, and no resource is locked. Wrapping this in a GenServer adds serialisation overhead on what could be massively parallel conversion requests (e.g., converting catalogue product weights in bulk). |

```elixir
defmodule Inventory.UnitConverter do
  use GenServer

  @moduledoc """
  Converts physical quantities between compatible units of measurement.
  Used by the product catalogue service for displaying weights, volumes,
  and dimensions in user-preferred units.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because converting units is purely arithmetic
  # — multiply by a conversion factor from a static table. The GenServer holds
  # no mutable state; its state map is always empty. All conversion requests
  # (e.g., during catalogue import of thousands of products) must be processed
  # sequentially through a single process with no benefit from concurrency.

  @conversions %{
    weight: %{
      kg:  1.0,
      g:   0.001,
      lb:  0.45359237,
      oz:  0.02834952,
      ton: 1000.0
    },
    length: %{
      m:   1.0,
      km:  1000.0,
      cm:  0.01,
      mm:  0.001,
      ft:  0.3048,
      in:  0.0254,
      yd:  0.9144,
      mi:  1609.344
    },
    volume: %{
      l:    1.0,
      ml:   0.001,
      cl:   0.01,
      m3:   1000.0,
      gal:  3.785411784,
      qt:   0.946352946,
      pt:   0.473176473,
      fl_oz: 0.02957352956
    },
    temperature: %{
      celsius:    :special,
      fahrenheit: :special,
      kelvin:     :special
    }
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Converts `value` from `from_unit` to `to_unit` within `category`.
  Returns `{:ok, converted_value}` or `{:error, reason}`.
  """
  def convert(pid, value, from_unit, to_unit, category) do
    GenServer.call(pid, {:convert, value, from_unit, to_unit, category})
  end

  @doc "Converts `value` in `unit` to the base unit for `category`."
  def to_base(pid, value, unit, category) do
    GenServer.call(pid, {:to_base, value, unit, category})
  end

  @doc "Converts `value` in the base unit of `category` to `unit`."
  def from_base(pid, value, unit, category) do
    GenServer.call(pid, {:from_base, value, unit, category})
  end

  @doc "Returns true if `unit_a` and `unit_b` belong to the same category."
  def compatible?(pid, unit_a, unit_b) do
    GenServer.call(pid, {:compatible?, unit_a, unit_b})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:convert, value, from, to, :temperature}, _from, state) do
    result = convert_temperature(value, from, to)
    {:reply, result, state}
  end

  def handle_call({:convert, value, from, to, category}, _from, state) do
    result =
      with {:ok, units}       <- Map.fetch(@conversions, category),
           {:ok, from_factor} <- Map.fetch(units, from),
           {:ok, to_factor}   <- Map.fetch(units, to) do
        base_value = value * from_factor
        {:ok, Float.round(base_value / to_factor, 6)}
      else
        :error -> {:error, :unknown_unit_or_category}
      end

    {:reply, result, state}
  end

  def handle_call({:to_base, value, unit, category}, _from, state) do
    result =
      with {:ok, units}  <- Map.fetch(@conversions, category),
           {:ok, factor} <- Map.fetch(units, unit),
           true          <- is_number(factor) do
        {:ok, Float.round(value * factor, 6)}
      else
        _ -> {:error, :unknown_unit_or_category}
      end

    {:reply, result, state}
  end

  def handle_call({:from_base, value, unit, category}, _from, state) do
    result =
      with {:ok, units}  <- Map.fetch(@conversions, category),
           {:ok, factor} <- Map.fetch(units, unit),
           true          <- is_number(factor) do
        {:ok, Float.round(value / factor, 6)}
      else
        _ -> {:error, :unknown_unit_or_category}
      end

    {:reply, result, state}
  end

  def handle_call({:compatible?, unit_a, unit_b}, _from, state) do
    result =
      Enum.any?(@conversions, fn {_cat, units} ->
        Map.has_key?(units, unit_a) and Map.has_key?(units, unit_b)
      end)

    {:reply, result, state}
  end

  ## Private helpers

  defp convert_temperature(v, :celsius, :fahrenheit), do: {:ok, v * 9 / 5 + 32}
  defp convert_temperature(v, :celsius, :kelvin),     do: {:ok, v + 273.15}
  defp convert_temperature(v, :fahrenheit, :celsius), do: {:ok, (v - 32) * 5 / 9}
  defp convert_temperature(v, :fahrenheit, :kelvin),  do: {:ok, (v - 32) * 5 / 9 + 273.15}
  defp convert_temperature(v, :kelvin, :celsius),     do: {:ok, v - 273.15}
  defp convert_temperature(v, :kelvin, :fahrenheit),  do: {:ok, (v - 273.15) * 9 / 5 + 32}
  defp convert_temperature(v, same, same),             do: {:ok, v}
  defp convert_temperature(_, _, _),                   do: {:error, :unknown_temperature_unit}

  # VALIDATION: SMELL END
end
```
