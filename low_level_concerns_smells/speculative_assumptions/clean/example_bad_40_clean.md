```elixir
defmodule AccessControl.PermissionDecoder do
  @moduledoc """
  Decodes compact permission bitmasks stored as integer strings in the
  user session and access control lists. Each bit corresponds to a
  specific system capability.

  Bit layout:
    Bit 0  (1)    - read_records
    Bit 1  (2)    - write_records
    Bit 2  (4)    - delete_records
    Bit 3  (8)    - export_data
    Bit 4  (16)   - manage_users
    Bit 5  (32)   - manage_roles
    Bit 6  (64)   - view_audit_log
    Bit 7  (128)  - configure_system
    Bit 8  (256)  - billing_access
    Bit 9  (512)  - api_access
  """

  require Logger

  @permission_bits [
    {:read_records,     1},
    {:write_records,    2},
    {:delete_records,   4},
    {:export_data,      8},
    {:manage_users,     16},
    {:manage_roles,     32},
    {:view_audit_log,   64},
    {:configure_system, 128},
    {:billing_access,   256},
    {:api_access,       512}
  ]

  @all_permissions @permission_bits |> Enum.map(&elem(&1, 0))

  def decode(permission_string) when is_binary(permission_string) do
    bitmask = String.to_integer(permission_string)
    extract_permissions(bitmask)
  rescue
    _ ->
      Logger.warning("Failed to decode permission string: #{inspect(permission_string)}")
      empty_permissions()
  end

  def decode(nil), do: empty_permissions()
  def decode(_),   do: empty_permissions()

  def encode(permissions_map) when is_map(permissions_map) do
    bitmask =
      @permission_bits
      |> Enum.reduce(0, fn {perm, bit}, acc ->
        if Map.get(permissions_map, perm, false), do: acc + bit, else: acc
      end)

    Integer.to_string(bitmask)
  end

  defp extract_permissions(bitmask) do
    @permission_bits
    |> Enum.map(fn {perm, bit} ->
      {perm, (Bitwise.band(bitmask, bit) != 0)}
    end)
    |> Map.new()
  end

  defp empty_permissions do
    @permission_bits
    |> Enum.map(fn {perm, _bit} -> {perm, false} end)
    |> Map.new()
  end

  def has_permission?(permissions, permission) when is_atom(permission) do
    Map.get(permissions, permission, false)
  end

  def has_any?(permissions, permission_list) when is_list(permission_list) do
    Enum.any?(permission_list, &has_permission?(permissions, &1))
  end

  def has_all?(permissions, permission_list) when is_list(permission_list) do
    Enum.all?(permission_list, &has_permission?(permissions, &1))
  end

  def grant(permissions, permission) do
    Map.put(permissions, permission, true)
  end

  def revoke(permissions, permission) do
    Map.put(permissions, permission, false)
  end

  def grant_all do
    @all_permissions |> Enum.map(&{&1, true}) |> Map.new()
  end

  def list_granted(permissions) do
    permissions |> Enum.filter(fn {_, v} -> v end) |> Enum.map(&elem(&1, 0))
  end

  def describe(permissions) do
    granted = list_granted(permissions)

    if granted == [] do
      "No permissions"
    else
      "Permissions: #{granted |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")}"
    end
  end
end
```
