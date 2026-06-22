```elixir
defmodule Audit.FieldChange do
  @moduledoc false

  @type t :: %__MODULE__{
          field: atom(),
          old_value: term(),
          new_value: term()
        }

  defstruct [:field, :old_value, :new_value]
end

defmodule Audit.AuditEntry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          resource_type: String.t(),
          resource_id: String.t(),
          actor_id: String.t() | nil,
          action: String.t(),
          changes: map(),
          occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_entries" do
    field :resource_type, :string
    field :resource_id, :string
    field :actor_id, :string
    field :action, :string
    field :changes, :map
    field :occurred_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, params) do
    entry
    |> cast(params, [:resource_type, :resource_id, :actor_id, :action, :changes, :occurred_at])
    |> validate_required([:resource_type, :resource_id, :action, :occurred_at])
  end
end

defmodule Audit.ChangesetRecorder do
  @moduledoc """
  Records field-level changes from Ecto changesets into a structured audit trail.

  Call `record/4` inside the same `Ecto.Multi` as your domain write so that
  the audit entry is persisted atomically with the business change.
  Fields containing secrets can be excluded via the `:exclude` option to
  prevent sensitive values from appearing in the audit log.
  """

  alias Audit.{AuditEntry, FieldChange}

  @type opts :: [
          actor_id: String.t() | nil,
          action: String.t(),
          exclude: [atom()]
        ]

  @spec record(Ecto.Multi.t(), atom(), Ecto.Changeset.t(), opts()) :: Ecto.Multi.t()
  def record(%Ecto.Multi{} = multi, step_name, %Ecto.Changeset{} = changeset, opts) do
    entry_changeset = build_entry(changeset, opts)
    Ecto.Multi.insert(multi, step_name, entry_changeset)
  end

  @spec extract_changes(Ecto.Changeset.t(), [atom()]) :: [FieldChange.t()]
  def extract_changes(%Ecto.Changeset{} = changeset, exclude \\ []) do
    changeset.changes
    |> Enum.reject(fn {field, _} -> field in exclude end)
    |> Enum.map(fn {field, new_value} ->
      old_value = Map.get(changeset.data, field)
      %FieldChange{field: field, old_value: old_value, new_value: new_value}
    end)
  end

  defp build_entry(%Ecto.Changeset{} = changeset, opts) do
    exclude = Keyword.get(opts, :exclude, [:password, :password_hash, :secret, :token])
    action = Keyword.get(opts, :action, infer_action(changeset))
    actor_id = Keyword.get(opts, :actor_id)

    changes_map =
      changeset.changes
      |> Map.drop(exclude)
      |> Map.new(fn {k, v} ->
        old = Map.get(changeset.data, k)
        {Atom.to_string(k), %{"from" => serialize(old), "to" => serialize(v)}}
      end)

    resource_id =
      case changeset.data do
        %{id: id} when not is_nil(id) -> to_string(id)
        _ -> nil
      end

    AuditEntry.changeset(%AuditEntry{}, %{
      resource_type: resource_type(changeset),
      resource_id: resource_id,
      actor_id: actor_id,
      action: action,
      changes: changes_map,
      occurred_at: DateTime.utc_now()
    })
  end

  defp infer_action(%Ecto.Changeset{action: :insert}), do: "created"
  defp infer_action(%Ecto.Changeset{action: :update}), do: "updated"
  defp infer_action(%Ecto.Changeset{action: :delete}), do: "deleted"
  defp infer_action(_), do: "changed"

  defp resource_type(%Ecto.Changeset{data: %module{}}), do: module |> to_string() |> String.replace("Elixir.", "")

  defp serialize(nil), do: nil
  defp serialize(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp serialize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize(%Date{} = d), do: Date.to_string(d)
  defp serialize(v), do: inspect(v)
end
```
