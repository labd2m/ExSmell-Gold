```elixir
defmodule Logistics.AddressFormatter do
  use GenServer

  @moduledoc """
  Formats and validates postal address structures for use in shipping
  labels, invoice headers, and customer profile displays.
  """

  @required_fields [:line1, :city, :country_code]

  @country_formats %{
    "US" => [:name, :line1, :line2, :city_state_zip, :country],
    "GB" => [:name, :line1, :line2, :city, :postcode, :country],
    "DE" => [:name, :line1, :line2, :zip_city, :country],
    "FR" => [:name, :line1, :line2, :zip_city, :country],
    "BR" => [:name, :line1, :line2, :city_state_zip, :country],
    "AU" => [:name, :line1, :line2, :city_state_zip, :country]
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Formats an `address` map into a multi-line string appropriate for
  the address's country. Returns `{:ok, string}` or `{:error, reason}`.
  """
  def format(pid, address) do
    GenServer.call(pid, {:format, address})
  end

  @doc "Formats an address into a compact single-line representation."
  def format_single_line(pid, address) do
    GenServer.call(pid, {:format_single_line, address})
  end

  @doc "Validates that required fields are present and non-empty."
  def validate(pid, address) do
    GenServer.call(pid, {:validate, address})
  end

  @doc "Returns a normalised address map with trimmed, capitalised fields."
  def normalize(pid, address) do
    GenServer.call(pid, {:normalize, address})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:validate, address}, _from, state) do
    missing =
      Enum.filter(@required_fields, fn field ->
        case Map.get(address, field) do
          nil -> true
          ""  -> true
          _   -> false
        end
      end)

    result =
      if missing == [],
        do: :ok,
        else: {:error, {:missing_fields, missing}}

    {:reply, result, state}
  end

  def handle_call({:normalize, address}, _from, state) do
    normalized =
      Map.new(address, fn {k, v} ->
        {k, if(is_binary(v), do: v |> String.trim() |> String.upcase(), else: v)}
      end)

    {:reply, {:ok, normalized}, state}
  end

  def handle_call({:format, address}, _from, state) do
    country = Map.get(address, :country_code, "US")
    format_keys = Map.get(@country_formats, country, @country_formats["US"])

    lines =
      format_keys
      |> Enum.map(fn key -> render_line(key, address) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:reply, {:ok, lines}, state}
  end

  def handle_call({:format_single_line, address}, _from, state) do
    parts =
      [
        Map.get(address, :line1),
        Map.get(address, :line2),
        Map.get(address, :city),
        Map.get(address, :state),
        Map.get(address, :postcode),
        Map.get(address, :country_code)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    {:reply, {:ok, parts}, state}
  end

  ## Private helpers

  defp render_line(:name, addr),          do: Map.get(addr, :name, "")
  defp render_line(:line1, addr),         do: Map.get(addr, :line1, "")
  defp render_line(:line2, addr),         do: Map.get(addr, :line2, "") || ""
  defp render_line(:city, addr),          do: Map.get(addr, :city, "")
  defp render_line(:postcode, addr),      do: Map.get(addr, :postcode, "")
  defp render_line(:country, addr),       do: Map.get(addr, :country_code, "")
  defp render_line(:city_state_zip, addr) do
    [Map.get(addr, :city), Map.get(addr, :state), Map.get(addr, :postcode)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end
  defp render_line(:zip_city, addr) do
    "#{Map.get(addr, :postcode, "")} #{Map.get(addr, :city, "")}" |> String.trim()
  end
  defp render_line(_, _), do: ""

end
```
