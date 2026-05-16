```elixir
defmodule HR.EmployeeDirectory do
  @moduledoc """
  Provides employee lookup and directory search capabilities.
  Used by HR workflows, reporting pipelines, and the internal employee portal.
  """

  alias HR.Repo
  alias HR.Schema.Employee

  import Ecto.Query

  @doc """
  Looks up one or more employees based on a given criterion.

  ## Options

    * `:by` — Determines the lookup strategy and return shape:
      - `:id` (default) — Fetch a single employee by ID. Returns `%Employee{}` or raises.
      - `:email` — Fetch a single employee by email. Returns `%Employee{} | nil`.
      - `:department` — Fetch all employees in a department. Returns `[%Employee{}]`.
      - `:manager` — Fetch all direct reports of the given manager ID. Returns `[%Employee{}]`.
    * `:active_only` — When `true`, restricts results to active employees.

  ## Examples

      iex> lookup(1)
      %Employee{id: 1, name: "Alice", ...}

      iex> lookup("alice@example.com", by: :email)
      %Employee{id: 1, email: "alice@example.com", ...}

      iex> lookup("engineering", by: :department)
      [%Employee{...}, %Employee{...}]

      iex> lookup(5, by: :manager)
      [%Employee{manager_id: 5, ...}, ...]

  """

  def lookup(value, opts \\ []) when is_list(opts) do
    active_only = Keyword.get(opts, :active_only, false)

    case Keyword.get(opts, :by, :id) do
      :id ->
        Repo.get!(Employee, value)

      :email ->
        query = from(e in Employee, where: e.email == ^value)
        query = if active_only, do: where(query, [e], e.active == true), else: query
        Repo.one(query)

      :department ->
        query = from(e in Employee, where: e.department == ^value, order_by: [asc: e.name])
        query = if active_only, do: where(query, [e], e.active == true), else: query
        Repo.all(query)

      :manager ->
        query = from(e in Employee, where: e.manager_id == ^value, order_by: [asc: e.name])
        query = if active_only, do: where(query, [e], e.active == true), else: query
        Repo.all(query)

      other ->
        raise ArgumentError, "Unsupported :by option #{inspect(other)}"
    end
  end

  @doc """
  Returns all employees whose names match a case-insensitive substring.
  """
  def search_by_name(query_string, opts \\ []) do
    active_only = Keyword.get(opts, :active_only, true)
    like = "%#{query_string}%"

    base_query =
      from(e in Employee,
        where: ilike(e.name, ^like),
        order_by: [asc: e.name]
      )

    if active_only do
      base_query
      |> where([e], e.active == true)
      |> Repo.all()
    else
      Repo.all(base_query)
    end
  end

  @doc """
  Returns the reporting chain from `employee_id` up to the root manager.
  Returns a list ordered from direct manager to root.
  """
  def reporting_chain(employee_id) do
    build_chain(employee_id, [])
  end

  defp build_chain(nil, acc), do: Enum.reverse(acc)

  defp build_chain(employee_id, acc) do
    case Repo.get(Employee, employee_id) do
      nil -> Enum.reverse(acc)
      %Employee{manager_id: manager_id} = emp -> build_chain(manager_id, [emp | acc])
    end
  end

  @doc """
  Returns the headcount per department.
  """
  def headcount_by_department do
    Employee
    |> where([e], e.active == true)
    |> group_by([e], e.department)
    |> select([e], {e.department, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Offboards an employee by marking them inactive and clearing their manager assignments.
  """
  def offboard(%Employee{} = employee) do
    Repo.transaction(fn ->
      employee
      |> Employee.changeset(%{active: false, offboarded_at: DateTime.utc_now()})
      |> Repo.update!()

      Employee
      |> where([e], e.manager_id == ^employee.id)
      |> Repo.update_all(set: [manager_id: nil])
    end)
  end
end
```
