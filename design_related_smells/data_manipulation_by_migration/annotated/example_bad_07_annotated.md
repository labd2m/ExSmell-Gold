# Annotated Bad Example 07

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddDepartmentCodeToEmployees`
- **Affected function(s):** `change/0`, `assign_department_codes/0`
- **Short explanation:** The migration adds a `department_code` column to `employees` (structural change) and also reads all employee records to derive and write the department code from their job title (data manipulation). These responsibilities should be split between the migration and a Mix task.

---

## Code

```elixir
defmodule HR.Repo.Migrations.AddDepartmentCodeToEmployees do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration module is responsible for both
  # adding :department_code and :cost_center columns (schema change) and scanning
  # all employees to infer and persist department codes based on job title patterns
  # (data manipulation). The backfill logic should not be inside Ecto.Migration.

  import Ecto.Query
  alias HR.Workforce.Employee
  alias HR.Repo

  @title_to_department [
    {~r/engineer|developer|architect/i, "ENG"},
    {~r/designer|ux|ui/i, "DES"},
    {~r/product manager|pm\b/i, "PRD"},
    {~r/sales|account executive|ae\b/i, "SAL"},
    {~r/finance|accountant|controller/i, "FIN"},
    {~r/hr|human resources|recruiter/i, "PEO"},
    {~r/marketing|growth|seo/i, "MKT"}
  ]

  @default_department "GEN"

  def change do
    alter table("employees") do
      add :department_code, :string, size: 5, null: false, default: @default_department
      add :cost_center, :string, size: 10
    end

    create index("employees", [:department_code])
    create index("employees", [:cost_center])

    flush()

    assign_department_codes()
  end

  defp assign_department_codes do
    from(e in Employee,
      where: e.employment_status == "active",
      select: %{id: e.id, job_title: e.job_title}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, job_title: title} ->
      dept = infer_department(title)

      from(e in Employee, where: e.id == ^id)
      |> Repo.update_all(set: [department_code: dept])
    end)
  end

  defp infer_department(nil), do: @default_department

  defp infer_department(title) do
    case Enum.find(@title_to_department, fn {regex, _} -> Regex.match?(regex, title) end) do
      {_, code} -> code
      nil       -> @default_department
    end
  end

  # VALIDATION: SMELL END
end
```
