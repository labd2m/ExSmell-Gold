# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `AccessControl` module, top-level directive
- **Affected function(s):** `authorize/3`, `effective_permissions/2`, `audit_access/3`
- **Short explanation:** `AccessControl` calls `use PolicyHelpers` to obtain permission-evaluation and bitmask utilities. The `__using__/1` macro of `PolicyHelpers` silently injects an `import` of `BitPermissions` into the caller, making `mask_for/1`, `has_permission?/2`, and `combine/1` available without any explicit declaration in `AccessControl`. Replacing `use PolicyHelpers` with `import PolicyHelpers` would make every dependency visible to readers of `AccessControl` alone.

---

```elixir
defmodule BitPermissions do
  @perms %{
    read:         0b00000001,
    write:        0b00000010,
    delete:       0b00000100,
    admin:        0b00001000,
    billing:      0b00010000,
    export:       0b00100000,
    impersonate:  0b01000000,
    super_admin:  0b11111111
  }

  def mask_for(permission_names) when is_list(permission_names) do
    Enum.reduce(permission_names, 0, fn name, acc ->
      acc ||| Map.get(@perms, name, 0)
    end)
  end

  def has_permission?(user_mask, permission) do
    perm_bit = Map.get(@perms, permission, 0)
    (user_mask &&& perm_bit) == perm_bit
  end

  def combine(masks) when is_list(masks) do
    Enum.reduce(masks, 0, fn m, acc -> acc ||| m end)
  end

  def all_permissions(mask) do
    @perms
    |> Enum.filter(fn {_, bit} -> (mask &&& bit) == bit end)
    |> Enum.map(&elem(&1, 0))
  end
end

defmodule PolicyHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import BitPermissions`
      # VALIDATION: into AccessControl. mask_for/1, has_permission?/2, combine/1, and
      # VALIDATION: all_permissions/1 appear in AccessControl as if they were local,
      # VALIDATION: but they actually originate from BitPermissions. This hidden
      # VALIDATION: propagation means the full dependency graph is not visible from
      # VALIDATION: reading AccessControl alone. `import PolicyHelpers` would be the
      # VALIDATION: appropriate, transparent alternative.
      import BitPermissions
      # VALIDATION: SMELL END

      def superuser?(%{role: :super_admin}), do: true
      def superuser?(_), do: false

      def owns_resource?(%{id: uid}, %{owner_id: oid}), do: uid == oid
      def owns_resource?(_, _), do: false

      def within_org?(%{org_id: uid_org}, %{org_id: res_org}), do: uid_org == res_org
      def within_org?(_, _), do: false
    end
  end
end

defmodule AccessControl do
  use PolicyHelpers

  @public_routes  ["/health", "/login", "/register"]
  @admin_routes   ["/admin", "/billing", "/reports"]

  def authorize(user, action, resource) do
    cond do
      superuser?(user) ->
        {:ok, :super_admin_bypass}

      owns_resource?(user, resource) and can_perform?(user, action) ->
        {:ok, :owner_access}

      within_org?(user, resource) and can_perform?(user, action) ->
        {:ok, :org_access}

      true ->
        {:error, :unauthorized}
    end
  end

  def effective_permissions(user, role_masks) do
    role_mask  = Map.get(role_masks, user.role, 0)
    extra_mask = mask_for(user.extra_permissions || [])
    full_mask  = combine([role_mask, extra_mask])
    all_permissions(full_mask)
  end

  def can_access_route?(user, path) do
    cond do
      path in @public_routes ->
        true
      path in @admin_routes ->
        has_permission?(user.permission_mask, :admin) or superuser?(user)
      true ->
        has_permission?(user.permission_mask, :read)
    end
  end

  def audit_access(user, action, resource) do
    {:ok, result} = authorize(user, action, resource)
    %{
      user_id:     user.id,
      action:      action,
      resource_id: resource.id,
      result:      result,
      permissions: effective_permissions(user, default_role_masks()),
      checked_at:  DateTime.utc_now()
    }
  end

  def build_permission_context(user) do
    %{
      user_id:     user.id,
      role:        user.role,
      mask:        user.permission_mask,
      permissions: all_permissions(user.permission_mask),
      is_admin:    has_permission?(user.permission_mask, :admin),
      is_super:    superuser?(user)
    }
  end

  defp can_perform?(%{permission_mask: mask}, action) do
    has_permission?(mask, action)
  end

  defp default_role_masks do
    %{
      viewer:  mask_for([:read]),
      editor:  mask_for([:read, :write]),
      admin:   mask_for([:read, :write, :delete, :admin]),
      billing: mask_for([:read, :billing, :export])
    }
  end
end
```
