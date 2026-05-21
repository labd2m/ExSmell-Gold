```elixir
defmodule Geo.AddressNormalizer do
  use GenServer

  @moduledoc """
  Normalizes, validates, and formats postal addresses for storage and display.
  Used during user onboarding, checkout, and bulk address import pipelines.
  """

  @state_abbreviations %{
    "alabama" => "AL", "alaska" => "AK", "arizona" => "AZ",
    "arkansas" => "AR", "california" => "CA", "colorado" => "CO",
    "connecticut" => "CT", "delaware" => "DE", "florida" => "FL",
    "georgia" => "GA", "hawaii" => "HI", "idaho" => "ID",
    "illinois" => "IL", "indiana" => "IN", "iowa" => "IA",
    "kansas" => "KS", "kentucky" => "KY", "louisiana" => "LA",
    "maine" => "ME", "maryland" => "MD", "massachusetts" => "MA",
    "michigan" => "MI", "minnesota" => "MN", "mississippi" => "MS",
    "missouri" => "MO", "texas" => "TX", "new york" => "NY",
    "new jersey" => "NJ", "washington" => "WA", "oregon" => "OR"
  }

  @street_suffixes %{
    "street" => "St", "avenue" => "Ave", "boulevard" => "Blvd",
    "drive" => "Dr", "lane" => "Ln", "road" => "Rd",
    "court" => "Ct", "circle" => "Cir", "place" => "Pl",
    "way" => "Way", "terrace" => "Ter", "highway" => "Hwy"
  }



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns a normalized address map with standardized casing and abbreviations.
  """
  def normalize(pid, address) do
    GenServer.call(pid, {:normalize, address})
  end

  @doc """
  Returns a single-line formatted string for labels and display.
  """
  def format_one_line(pid, address) do
    GenServer.call(pid, {:format_one_line, address})
  end

  @doc """
  Extracts components (street number, street name, unit, etc.) from a raw string.
  """
  def extract_components(pid, raw_address) do
    GenServer.call(pid, {:extract_components, raw_address})
  end

  @doc """
  Validates that all required address fields are present and non-empty.
  """
  def validate(pid, address) do
    GenServer.call(pid, {:validate, address})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:normalize, address}, _from, state) do
    normalized = %{
      street: normalize_street(Map.get(address, :street, "")),
      city: title_case(Map.get(address, :city, "")),
      state: normalize_state(Map.get(address, :state, "")),
      zip: normalize_zip(Map.get(address, :zip, "")),
      country: String.upcase(Map.get(address, :country, "US"))
    }

    {:reply, {:ok, normalized}, state}
  end

  @impl true
  def handle_call({:format_one_line, address}, _from, state) do
    parts = [
      Map.get(address, :street),
      Map.get(address, :city),
      "#{Map.get(address, :state)} #{Map.get(address, :zip)}" |> String.trim(),
      Map.get(address, :country)
    ]

    line =
      parts
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(", ")

    {:reply, {:ok, line}, state}
  end

  @impl true
  def handle_call({:extract_components, raw}, _from, state) do
    result =
      case Regex.run(~r/^(\d+)\s+(.+?)(?:\s+(?:Apt|Unit|Suite|#)\s*(\S+))?\s*$/i, raw) do
        [_, number, street | rest] ->
          unit = List.first(rest)
          {:ok, %{number: number, street: String.trim(street), unit: unit}}

        nil ->
          {:error, "Could not parse address: #{raw}"}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate, address}, _from, state) do
    required = [:street, :city, :state, :zip]

    missing =
      Enum.filter(required, fn field ->
        value = Map.get(address, field, "")
        is_nil(value) or String.trim(to_string(value)) == ""
      end)

    result =
      if missing == [] do
        {:ok, address}
      else
        {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
      end

    {:reply, result, state}
  end

  defp normalize_street(street) do
    words = String.split(street, " ")

    normalized =
      Enum.map(words, fn word ->
        lower = String.downcase(word)
        Map.get(@street_suffixes, lower, title_case(word))
      end)

    Enum.join(normalized, " ")
  end

  defp normalize_state(state) do
    lower = String.downcase(String.trim(state))

    cond do
      String.length(lower) == 2 -> String.upcase(lower)
      Map.has_key?(@state_abbreviations, lower) -> @state_abbreviations[lower]
      true -> String.upcase(state)
    end
  end

  defp normalize_zip(zip) do
    zip
    |> String.replace(~r/[^\d-]/, "")
    |> String.slice(0, 10)
  end

  defp title_case(str) do
    str
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
```
