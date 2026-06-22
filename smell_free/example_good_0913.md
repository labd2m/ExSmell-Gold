```elixir
defmodule Platform.CapabilityRegistry do
  @moduledoc """
  Maintains a registry of named runtime capabilities and their feature
  dependencies. A capability is enabled only when all of its required
  features are active in the `Platform.FeatureRegistry`. The capability
  registry is read-only at runtime; all definitions are loaded from
  application configuration at startup and cached in a module attribute.
  """

  @type capability_name :: atom()
  @type capability_def :: %{
          name: capability_name(),
          description: String.t(),
          required_features: [String.t()]
        }

  @capabilities Application.compile_env(:my_app, :capabilities, [])
  @capability_map Map.new(@capabilities, fn cap -> {cap.name, cap} end)

  @doc "Returns the definition for `capability`, or `nil` when unknown."
  @spec definition(capability_name()) :: capability_def() | nil
  def definition(name) when is_atom(name), do: Map.get(@capability_map, name)

  @doc """
  Returns true when `capability` is currently enabled, meaning all its
  required features are active in `Platform.FeatureRegistry`.
  """
  @spec enabled?(capability_name()) :: boolean()
  def enabled?(name) when is_atom(name) do
    case Map.get(@capability_map, name) do
      nil ->
        false

      %{required_features: features} ->
        Enum.all?(features, &Platform.FeatureRegistry.enabled?/1)
    end
  end

  @doc "Returns all capability names whose required features are currently active."
  @spec active_capabilities() :: [capability_name()]
  def active_capabilities do
    @capability_map
    |> Map.keys()
    |> Enum.filter(&enabled?/1)
  end

  @doc """
  Returns all capability names that are currently disabled, along with
  the first missing feature for each.
  """
  @spec disabled_capabilities() :: [{capability_name(), missing_feature :: String.t()}]
  def disabled_capabilities do
    @capability_map
    |> Enum.flat_map(fn {name, %{required_features: features}} ->
      missing = Enum.find(features, fn f -> not Platform.FeatureRegistry.enabled?(f) end)
      if missing, do: [{name, missing}], else: []
    end)
  end

  @doc "Returns all registered capability names in sorted order."
  @spec all_names() :: [capability_name()]
  def all_names, do: @capability_map |> Map.keys() |> Enum.sort()

  @doc "Returns the required feature names for `capability`."
  @spec required_features(capability_name()) :: [String.t()]
  def required_features(name) when is_atom(name) do
    case Map.get(@capability_map, name) do
      nil -> []
      %{required_features: features} -> features
    end
  end
end
```
