# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `field_name_to_atom/1` called inside `apply_patch/2`
- **Affected function(s):** `field_name_to_atom/1`, `apply_patch/2`
- **Short explanation:** The function converts field name strings from a JSON PATCH request body into atoms using `String.to_atom/1`. JSON PATCH operations specify field paths as strings from the client, and any arbitrary field name becomes a permanent atom, giving external clients direct control over the atom table.

---

```elixir
defmodule UserManagement.ProfilePatcher do
  @moduledoc """
  Applies JSON PATCH operations to user profile records.
  Supports partial updates to profile fields without full document replacement.
  """

  require Logger

  alias UserManagement.{UserRepo, ChangesetValidator, AuditLog}

  @patchable_fields ~w(first_name last_name phone bio timezone locale avatar_url)
  @max_operations 20

  @spec patch(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def patch(user_id, operations) when is_list(operations) do
    Logger.info("Applying profile patch", user_id: user_id, op_count: length(operations))

    with :ok <- validate_operation_count(operations),
         {:ok, user} <- UserRepo.get(user_id),
         {:ok, ops} <- parse_operations(operations),
         {:ok, changes} <- apply_patch(user, ops),
         :ok <- ChangesetValidator.validate(changes),
         {:ok, updated_user} <- UserRepo.update(user, changes),
         :ok <- AuditLog.record(:profile_patched, user_id, ops) do
      Logger.info("Profile patch applied", user_id: user_id)
      {:ok, updated_user}
    else
      {:error, reason} = err ->
        Logger.error("Profile patch failed", user_id: user_id, reason: inspect(reason))
        err
    end
  end

  defp validate_operation_count(ops) when length(ops) <= @max_operations, do: :ok
  defp validate_operation_count(_), do: {:error, :too_many_operations}

  defp parse_operations(operations) do
    results =
      Enum.map(operations, fn
        %{"op" => "replace", "path" => path, "value" => value} ->
          {:ok, %{op: :replace, path: path, value: value}}

        %{"op" => "remove", "path" => path} ->
          {:ok, %{op: :remove, path: path, value: nil}}

        other ->
          Logger.warning("Unsupported PATCH operation", op: inspect(other))
          {:error, {:unsupported_operation, other}}
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, op} -> op end)}
    else
      {:error, {:invalid_operations, errors}}
    end
  end

  defp apply_patch(user, ops) do
    Enum.reduce_while(ops, {:ok, %{}}, fn op, {:ok, acc} ->
      field_name = String.trim_leading(op.path, "/")

      if field_name not in @patchable_fields do
        {:halt, {:error, {:unpatchable_field, field_name}}}
      else
        # VALIDATION: SMELL START - Dynamic atom creation
        # VALIDATION: This is a smell because `field_name_to_atom/1` calls
        # `String.to_atom/1` on field name strings extracted from a client JSON
        # PATCH body. Although there is a guard against non-patchable fields,
        # the conversion to atom still happens with an unconstrained runtime
        # string. If the allowlist check were loosened, or if the same pattern
        # is reused without the guard, arbitrary client input would create
        # unbounded atoms. Even with the guard, the conversion is inherently
        # unsafe as a general pattern.
        key = field_name_to_atom(field_name)
        # VALIDATION: SMELL END

        value = if op.op == :remove, do: nil, else: op.value
        {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp field_name_to_atom(name) when is_binary(name) do
    String.to_atom(name)
  end

  @spec patchable_fields() :: [String.t()]
  def patchable_fields, do: @patchable_fields
end
```
