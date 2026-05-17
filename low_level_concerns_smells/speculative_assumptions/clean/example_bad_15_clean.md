```elixir
defmodule UserManagement.EmployeeCodeParser do
  @moduledoc """
  Decodes structured employee codes used in the HR and access-management system.

  Employee codes are issued by the HR platform and encode organisational
  affiliation and access role in a single compact string:

    "<DEPARTMENT>.<EMPLOYEE_ID>.<ROLE>"

  Examples:
    "ENG.10042.developer"
    "FIN.20018.analyst"
    "OPS.30007.coordinator"
    "EXEC.40001.director"

  Employee codes are stored in the IdP as a custom attribute and are used
  to auto-provision access rights at login time.
  """

  require Logger

  @known_roles ~w(developer analyst coordinator director manager intern contractor viewer)

  defstruct [:department, :employee_id, :role, :raw]

  @doc """
  Decodes an employee code string into a `%EmployeeCodeParser{}` struct.

  Returns `{:ok, struct}` when the code is parseable and the role is known.
  Returns `{:error, reason}` when role validation fails.
  """

  def decode(code) when is_binary(code) do
    parts       = String.split(code, ".")
    department  = Enum.at(parts, 0)
    employee_id = Enum.at(parts, 1)
    role        = Enum.at(parts, 2)

    with :ok <- validate_role(role) do
      {:ok, %__MODULE__{
        department:  department,
        employee_id: parse_employee_id(employee_id),
        role:        role,
        raw:         code
      }}
    end
  end

  @doc """
  Decodes a list of employee codes and separates successful results from failures.
  """
  def decode_many(codes) when is_list(codes) do
    Enum.reduce(codes, %{ok: [], error: []}, fn code, acc ->
      case decode(code) do
        {:ok, emp}       -> %{acc | ok:    [emp | acc.ok]}
        {:error, reason} -> %{acc | error: [{code, reason} | acc.error]}
      end
    end)
    |> then(&%{&1 | ok: Enum.reverse(&1.ok), error: Enum.reverse(&1.error)})
  end

  @doc """
  Returns true if the decoded employee has an elevated access role.
  """
  def elevated_access?(%__MODULE__{role: role}) when role in ~w(director manager), do: true
  def elevated_access?(_), do: false

  @doc """
  Returns true if the decoded employee is a non-permanent staff member.
  """
  def temporary?(%__MODULE__{role: role}) when role in ~w(intern contractor), do: true
  def temporary?(_), do: false

  @doc """
  Formats an employee struct as a display string suitable for UI labels.
  """
  def display_label(%__MODULE__{department: dept, employee_id: id, role: role}) do
    "#{String.upcase(dept || "?")} ##{id} — #{String.capitalize(role || "unknown")}"
  end

  @doc """
  Builds a canonical LDAP-style distinguished name from an employee struct.
  """
  def to_dn(%__MODULE__{department: dept, employee_id: id}) do
    "CN=#{id},OU=#{dept},DC=corp,DC=example,DC=com"
  end

  @doc """
  Returns all supported role names.
  """
  def known_roles, do: @known_roles

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_role(nil), do: {:error, :missing_role}

  defp validate_role(role) when is_binary(role) do
    if role in @known_roles do
      :ok
    else
      {:error, {:unknown_role, role, @known_roles}}
    end
  end

  defp validate_role(_), do: {:error, :invalid_role}

  defp parse_employee_id(nil), do: nil

  defp parse_employee_id(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _       -> str
    end
  end
end
```
