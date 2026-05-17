```elixir
defmodule Logistics.ConsignmentParser do
  @moduledoc """
  Parses outbound consignment reference strings produced by the warehouse management system.

  Reference format:
    "CON-<YYYYMMDD>-<CARRIER>-<SERVICE_LEVEL>-<TRACKING_SUFFIX>"

  Examples:
    "CON-20240315-DHL-EXPRESS-AU42987654"
    "CON-20240315-AUSPOST-STANDARD-AP73628190"
    "CON-20240315-UPS-OVERNIGHT-1Z999AA10123456784"
  """

  require Logger

  @known_carriers ~w(DHL AUSPOST UPS FEDEX TNT STARTRACK COURIERS-PLEASE)
  @known_service_levels ~w(EXPRESS STANDARD OVERNIGHT ECONOMY SAMEDAY)

  @doc """
  Parses a list of raw consignment references from a WMS export batch.
  Returns a list of `{:ok, info}` or `{:error, ref, reason}` tuples.
  """
  def parse_batch(raw_refs) when is_list(raw_refs) do
    Enum.map(raw_refs, fn ref ->
      case extract_carrier_info(ref) do
        {:ok, info}      -> {:ok, info}
        {:error, reason} -> {:error, ref, reason}
      end
    end)
  end

  @doc """
  Extracts structured carrier information from a consignment reference string.
  """

  def extract_carrier_info(ref) when is_binary(ref) do
    parts = String.split(ref, "-")

    carrier       = Enum.at(parts, 2)
    service_level = Enum.at(parts, 3)
    tracking_sfx  = Enum.at(parts, 4)
    date_str      = Enum.at(parts, 1)

    {:ok, %{
      raw_reference:   ref,
      dispatched_on:   parse_date(date_str),
      carrier:         carrier,
      service_level:   service_level,
      tracking_suffix: tracking_sfx,
      full_tracking:   build_tracking_number(carrier, tracking_sfx)
    }}
  rescue
    e ->
      Logger.error("ConsignmentParser failed for #{inspect(ref)}: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Looks up the SLA (in business days) for a given carrier + service level combination.
  """
  def sla_days(carrier, service_level) do
    case {String.upcase(carrier || ""), String.upcase(service_level || "")} do
      {"DHL",      "EXPRESS"}   -> {:ok, 1}
      {"DHL",      "STANDARD"}  -> {:ok, 3}
      {"AUSPOST",  "EXPRESS"}   -> {:ok, 2}
      {"AUSPOST",  "STANDARD"}  -> {:ok, 5}
      {"UPS",      "OVERNIGHT"} -> {:ok, 1}
      {"UPS",      "ECONOMY"}   -> {:ok, 7}
      {"FEDEX",    "EXPRESS"}   -> {:ok, 1}
      {"STARTRACK","SAMEDAY"}   -> {:ok, 0}
      {c, s} ->
        Logger.warning("Unknown carrier/service combination: #{c}/#{s}")
        {:error, :unknown_combination}
    end
  end

  @doc """
  Returns true when the carrier is in the list of known/approved carriers.
  """
  def known_carrier?(carrier) when is_binary(carrier) do
    String.upcase(carrier) in @known_carriers
  end

  def known_carrier?(_), do: false

  @doc """
  Returns true when the service level is recognised by the platform.
  """
  def known_service_level?(level) when is_binary(level) do
    String.upcase(level) in @known_service_levels
  end

  def known_service_level?(_), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) and byte_size(str) == 8 do
    with <<y::binary-4, m::binary-2, d::binary-2>> <- str,
         {year,  ""}  <- Integer.parse(y),
         {month, ""}  <- Integer.parse(m),
         {day,   ""}  <- Integer.parse(d),
         {:ok, date}  <- Date.new(year, month, day) do
      date
    else
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp build_tracking_number(nil, _suffix), do: nil
  defp build_tracking_number(_carrier, nil), do: nil

  defp build_tracking_number(carrier, suffix) do
    "#{String.upcase(carrier)}-#{suffix}"
  end
end
```
