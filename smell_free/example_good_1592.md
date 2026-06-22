```elixir
defmodule RBAC.Permission do
  @moduledoc """
  A named capability that can be attached to roles.
  """

  @type t :: atom()
end

defmodule RBAC.Role do
  @moduledoc """
  A named role composed of a set of permissions.
  """

  @type t :: %__MODULE__{
          name: atom(),
          permissions: MapSet.t()
        }

  defstruct [:name, :permissions]

  @spec new(atom(), [RBAC.Permission.t()]) :: t()
  def new(name, permissions) when is_atom(name) and is_list(permissions) do
    %__MODULE__{name: name, permissions: MapSet.new(permissions)}
  end

  @spec has_permission?(t(), RBAC.Permission.t()) :: boolean()
  def has_permission?(%__MODULE__{permissions: perms}, permission) do
    MapSet.member?(perms, permission)
  end
end

defmodule RBAC.Policy do
  alias RBAC.Role

  @moduledoc """
  Defines the complete role hierarchy and evaluates authorization decisions.
  Policies are assembled from role definitions at startup and queried at runtime.
  """

  @type t :: %__MODULE__{roles: %{atom() => Role.t()}}
  defstruct roles: %{}

  @spec build([Role.t()]) :: t()
  def build(roles) when is_list(roles) do
    role_map = Map.new(roles, fn r -> {r.name, r} end)
    %__MODULE__{roles: role_map}
  end

  @spec authorized?(t(), [atom()], RBAC.Permission.t()) :: boolean()
  def authorized?(%__MODULE__{roles: role_map}, user_roles, permission)
      when is_list(user_roles) and is_atom(permission) do
    Enum.any?(user_roles, fn role_name ->
      case Map.fetch(role_map, role_name) do
        {:ok, role} -> Role.has_permission?(role, permission)
        :error -> false
      end
    end)
  end

  @spec permissions_for(t(), [atom()]) :: MapSet.t()
  def permissions_for(%__MODULE__{roles: role_map}, user_roles) when is_list(user_roles) do
    user_roles
    |> Enum.flat_map(fn role_name ->
      case Map.fetch(role_map, role_name) do
        {:ok, role} -> MapSet.to_list(role.permissions)
        :error -> []
      end
    end)
    |> MapSet.new()
  end
end

defmodule RBAC.Plug do
  @behaviour Plug

  import Plug.Conn

  @moduledoc """
  Enforces permission-based access on a Phoenix route.
  Requires `:current_user` and `:policy` in `conn.assigns`.
  """

  @impl Plug
  def init(opts) do
    permission = Keyword.fetch!(opts, :require)
    %{required_permission: permission}
  end

  @impl Plug
  def call(conn, %{required_permission: permission}) do
    user = conn.assigns[:current_user]
    policy = conn.assigns[:policy]

    if user && policy && RBAC.Policy.authorized?(policy, user.roles, permission) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "Forbidden."}))
      |> halt()
    end
  end
end
```
