```elixir
defmodule Notifications.TemplateRenderer do
  @moduledoc """
  Renders notification templates by substituting named variables with runtime
  values. Used by email, SMS, and push notification delivery pipelines.

  Templates use double-brace syntax: `{{variable_name}}`.
  """

  @max_template_size 10_000
  @variable_pattern ~r/\{\{(\w+)\}\}/

  @doc """
  Renders a notification template by substituting all declared variables.
  Returns `{:ok, rendered_string}` or `{:error, reason}`.

  ## Parameters
    - `template`: A binary template string with `{{var}}` placeholders.
    - `variables`: A map of variable names (strings or atoms) to their values.
  """
  def render(template, variables)
      when is_binary(template) and is_map(variables) do
    if byte_size(template) > @max_template_size do
      {:error, :template_too_large}
    else
      rendered =
        Regex.replace(@variable_pattern, template, fn _full, var_name ->
          key = String.to_existing_atom(var_name)
          value = Map.get(variables, key) || Map.get(variables, var_name) || ""
          interpolate_variable(var_name, value)
        end)

      {:ok, rendered}
    end
  rescue
    ArgumentError -> {:error, :unknown_variable}
  end

  @doc """
  Converts a single template variable value to its string representation
  for injection into the template body.
  """
 
  def interpolate_variable(_var_name, value) do
    to_string(value)
  end

  @doc """
  Returns all variable names declared in a template.
  """
  def declared_variables(template) when is_binary(template) do
    @variable_pattern
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Validates that all declared variables in the template have corresponding
  entries in the provided variables map.
  """
  def validate_variables(template, variables)
      when is_binary(template) and is_map(variables) do
    declared = declared_variables(template)

    missing =
      Enum.reject(declared, fn var_name ->
        Map.has_key?(variables, var_name) or
          Map.has_key?(variables, String.to_existing_atom(var_name))
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_variables, missing}}
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Renders a pre-defined system template by name and variables.
  """
  def render_system_template(template_name, variables)
      when is_atom(template_name) and is_map(variables) do
    case fetch_system_template(template_name) do
      {:ok, template} -> render(template, variables)
      {:error, _} = err -> err
    end
  end

  @doc """
  Strips all template variable placeholders from a string, useful for
  generating a plain-text preview without actual values.
  """
  def strip_variables(template) when is_binary(template) do
    Regex.replace(@variable_pattern, template, "")
  end

  # --- Private ---

  defp fetch_system_template(:welcome_email) do
    {:ok,
     "Hello {{first_name}}, welcome to our platform! " <>
       "Your account ({{email}}) is now active."}
  end

  defp fetch_system_template(:password_reset) do
    {:ok,
     "Hi {{first_name}}, click the link below to reset your password. " <>
       "This link expires in {{expiry_minutes}} minutes."}
  end

  defp fetch_system_template(:order_confirmed) do
    {:ok,
     "Your order #{{order_id}} has been confirmed. " <>
       "Estimated delivery: {{delivery_date}}."}
  end

  defp fetch_system_template(_), do: {:error, :template_not_found}
end
```
