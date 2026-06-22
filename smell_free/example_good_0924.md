```elixir
defmodule Platform.CommandValidator do
  @moduledoc """
  A composable validation pipeline for command structs.

  Validators are plain functions that receive the command and return
  `:ok` or `{:error, field, message}`. Multiple validators are run in
  order; the pipeline collects all errors rather than stopping at the
  first, so callers receive complete feedback in a single pass.
  """

  @type command :: struct()
  @type field :: atom() | String.t()
  @type validator :: (command() -> :ok | {:error, field(), String.t()})
  @type validation_result :: :ok | {:error, [%{field: field(), message: String.t()}]}

  @doc """
  Runs `validators` against `command`, collecting all errors.
  Returns `:ok` if all validators pass, or `{:error, errors}` with
  a list of field-level error maps.
  """
  @spec validate(command(), [validator()]) :: validation_result()
  def validate(command, validators) when is_list(validators) do
    errors =
      validators
      |> Enum.flat_map(fn validator ->
        case validator.(command) do
          :ok -> []
          {:error, field, message} -> [%{field: field, message: message}]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Builds a validator that checks `field` is not nil or blank.
  """
  @spec required(atom()) :: validator()
  def required(field) when is_atom(field) do
    fn command ->
      value = Map.get(command, field)
      case value do
        nil -> {:error, field, "is required"}
        "" -> {:error, field, "must not be blank"}
        _ -> :ok
      end
    end
  end

  @doc "Builds a validator that checks `field` is at least `min` characters."
  @spec min_length(atom(), pos_integer()) :: validator()
  def min_length(field, min) when is_atom(field) and is_integer(min) do
    fn command ->
      case Map.get(command, field) do
        value when is_binary(value) and byte_size(value) >= min -> :ok
        nil -> :ok
        _ -> {:error, field, "must be at least #{min} characters"}
      end
    end
  end

  @doc "Builds a validator that checks `field` matches the given format regex."
  @spec format(atom(), Regex.t(), String.t()) :: validator()
  def format(field, pattern, message) when is_atom(field) do
    fn command ->
      case Map.get(command, field) do
        nil -> :ok
        value when is_binary(value) ->
          if Regex.match?(pattern, value), do: :ok, else: {:error, field, message}
        _ -> {:error, field, message}
      end
    end
  end

  @doc "Builds a validator that checks `field` is one of `allowed_values`."
  @spec inclusion(atom(), [term()]) :: validator()
  def inclusion(field, allowed_values) when is_atom(field) and is_list(allowed_values) do
    fn command ->
      value = Map.get(command, field)
      if value in allowed_values do
        :ok
      else
        {:error, field, "must be one of #{inspect(allowed_values)}"}
      end
    end
  end

  @doc """
  Builds a validator that runs a custom check function.
  `check_fn` receives the command and returns `true` (pass) or `{false, message}`.
  """
  @spec custom(atom(), (command() -> true | {false, String.t()})) :: validator()
  def custom(field, check_fn) when is_atom(field) and is_function(check_fn, 1) do
    fn command ->
      case check_fn.(command) do
        true -> :ok
        {false, message} -> {:error, field, message}
      end
    end
  end

  @doc """
  Builds a validator that conditionally applies `inner_validator` only
  when `condition_fn` returns `true`.
  """
  @spec when_present(atom(), validator()) :: validator()
  def when_present(field, inner_validator) when is_atom(field) do
    fn command ->
      case Map.get(command, field) do
        nil -> :ok
        _ -> inner_validator.(command)
      end
    end
  end
end
```
