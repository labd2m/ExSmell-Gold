```elixir
defmodule HR.BadgeGenerator do
  @moduledoc """
  Generates and validates employee badge numbers for the HR platform.
  Badge numbers are used for physical access control, payroll linking,
  and directory look-ups.

  Format: `{DEPARTMENT_CODE}-{EMPLOYEE_ID}`, e.g. `ENG-004217`.
  """

  @id_pad_length 6
  @separator "-"
  @valid_department_pattern ~r/^[A-Z]{2,6}$/

  @doc """
  Builds a canonical badge number from a department code and employee identifier.

  ## Parameters
    - `department_code`: An uppercase department abbreviation, e.g. `"ENG"`.
    - `employee_id`: The employee's unique identifier (integer or string).
  """
  def build_badge_number(department_code, employee_id)
      when is_binary(department_code) do
    padded_id =
      employee_id
      |> to_string()
      |> String.pad_leading(@id_pad_length, "0")

    "#{String.upcase(department_code)}#{@separator}#{padded_id}"
  end

  @doc """
  Validates that a badge number conforms to the expected format.
  Returns `:ok` or `{:error, reason}`.
  """
  def validate_badge_number(badge) when is_binary(badge) do
    parts = String.split(badge, @separator, parts: 2)

    case parts do
      [dept, id_str] ->
        cond do
          not Regex.match?(@valid_department_pattern, dept) ->
            {:error, :invalid_department_code}

          not Regex.match?(~r/^\d+$/, id_str) ->
            {:error, :invalid_id_format}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_badge_format}
    end
  end

  def validate_badge_number(_), do: {:error, :invalid_badge_type}

  @doc """
  Extracts the department code portion from a badge number.
  """
  def department_from_badge(badge) when is_binary(badge) do
    case String.split(badge, @separator, parts: 2) do
      [dept, _] -> {:ok, dept}
      _ -> {:error, :invalid_badge_format}
    end
  end

  @doc """
  Extracts the numeric employee ID from a badge number.
  Returns the ID as an integer.
  """
  def employee_id_from_badge(badge) when is_binary(badge) do
    case String.split(badge, @separator, parts: 2) do
      [_, id_str] ->
        case Integer.parse(id_str) do
          {id, ""} -> {:ok, id}
          _ -> {:error, :non_integer_id}
        end

      _ ->
        {:error, :invalid_badge_format}
    end
  end

  @doc """
  Generates a batch of badge numbers for a list of `{department, employee_id}` tuples.
  """
  def generate_batch(assignments) when is_list(assignments) do
    Enum.map(assignments, fn {dept, emp_id} ->
      {dept, emp_id, build_badge_number(dept, emp_id)}
    end)
  end

  @doc """
  Returns a masked badge number for display in logs (hides the employee ID digits).
  """
  def mask_badge(badge) when is_binary(badge) do
    case String.split(badge, @separator, parts: 2) do
      [dept, _id] -> "#{dept}#{@separator}######"
      _ -> "INVALID"
    end
  end
end
```
