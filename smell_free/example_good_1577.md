```elixir
defmodule Templates.Variable do
  @moduledoc """
  A single named variable within a template with its resolved value and type.
  """

  @type var_type :: :string | :integer | :date | :currency_cents

  @type t :: %__MODULE__{name: String.t(), value: term(), type: var_type()}
  defstruct [:name, :value, :type]
end

defmodule Templates.Renderer do
  alias Templates.Variable

  @moduledoc """
  Renders string templates containing `{{variable_name}}` placeholders
  by substituting typed, formatted variable values.
  Unresolved variables are left as empty strings and reported separately.
  """

  @placeholder_pattern ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}/

  @type render_result :: %{
          output: String.t(),
          unresolved: [String.t()]
        }

  @spec render(String.t(), [Variable.t()]) :: {:ok, render_result()}
  def render(template, variables) when is_binary(template) and is_list(variables) do
    variable_map = Map.new(variables, fn v -> {v.name, v} end)
    referenced_names = extract_names(template)

    {output, unresolved} =
      Enum.reduce(referenced_names, {template, []}, fn name, {text, missing} ->
        case Map.fetch(variable_map, name) do
          {:ok, var} ->
            formatted = format_value(var)
            replaced = String.replace(text, "{{#{name}}}", formatted)
            {replaced, missing}

          :error ->
            replaced = String.replace(text, "{{#{name}}}", "")
            {replaced, missing ++ [name]}
        end
      end)

    {:ok, %{output: output, unresolved: unresolved}}
  end

  @spec extract_names(String.t()) :: [String.t()]
  def extract_names(template) when is_binary(template) do
    @placeholder_pattern
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  defp format_value(%Variable{type: :string, value: value}) when is_binary(value), do: value
  defp format_value(%Variable{type: :string, value: value}), do: to_string(value)

  defp format_value(%Variable{type: :integer, value: value}) when is_integer(value) do
    Integer.to_string(value)
  end

  defp format_value(%Variable{type: :date, value: %Date{} = date}) do
    Calendar.strftime(date, "%B %-d, %Y")
  end

  defp format_value(%Variable{type: :currency_cents, value: cents}) when is_integer(cents) do
    dollars = div(cents, 100)
    remaining = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(to_string(remaining), 2, "0")}"
  end
end

defmodule Templates.Library do
  @moduledoc """
  Stores and retrieves named template strings from the database.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias MyApp.Repo

  schema "email_templates" do
    field :key, :string
    field :subject, :string
    field :body, :string
    field :locale, :string, default: "en"
    timestamps()
  end

  @spec fetch(String.t(), String.t()) :: {:ok, %__MODULE__{}} | {:error, :not_found}
  def fetch(key, locale \\ "en") when is_binary(key) and is_binary(locale) do
    __MODULE__
    |> where([t], t.key == ^key and t.locale == ^locale)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:key, :subject, :body, :locale])
    |> validate_required([:key, :subject, :body])
    |> unique_constraint([:key, :locale])
  end
end
```
