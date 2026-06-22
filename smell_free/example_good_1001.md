```elixir
defmodule MyApp.Support.TicketTagging do
  @moduledoc """
  Applies an auto-tagging pipeline to new support tickets using keyword
  and pattern matching against the subject and body. Tags help route
  tickets to specialist queues and feed analytics dashboards without
  requiring manual categorisation by agents.

  Tags are stored as a plain string list on the `Ticket` record. The
  tagger is deterministic so it is safe to re-run on the same ticket.
  """

  alias MyApp.Repo
  alias MyApp.Support.Ticket

  @tag_rules [
    {"billing", ~w(invoice payment charge refund subscription), []},
    {"technical", ~w(error bug crash timeout not working), []},
    {"account", ~w(password login account access locked), []},
    {"shipping", ~w(delivery tracking shipped arrived lost), []},
    {"return", ~w(return refund exchange damaged wrong), []},
    {"feature_request", ~w(feature request suggestion idea improvement), []}
  ]

  @type tag :: String.t()

  @doc """
  Derives tags for `ticket` from its subject and body, persists them,
  and returns `{:ok, tags}`. Safe to call multiple times; the tag list
  is replaced on each call.
  """
  @spec tag(Ticket.t()) :: {:ok, [tag()]} | {:error, Ecto.Changeset.t()}
  def tag(%Ticket{} = ticket) do
    tags = derive_tags(ticket)

    ticket
    |> Ticket.changeset(%{auto_tags: tags})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated.auto_tags}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Returns the tags that would be applied to `ticket` without writing."
  @spec derive_tags(Ticket.t()) :: [tag()]
  def derive_tags(%Ticket{subject: subject, body: body}) do
    text = "#{subject} #{body}" |> String.downcase()

    @tag_rules
    |> Enum.flat_map(fn {tag, keywords, _patterns} ->
      if Enum.any?(keywords, &String.contains?(text, &1)), do: [tag], else: []
    end)
    |> maybe_add_urgency_tag(text)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec maybe_add_urgency_tag([tag()], String.t()) :: [tag()]
  defp maybe_add_urgency_tag(tags, text) do
    urgent_words = ~w(urgent asap immediately critical emergency)

    if Enum.any?(urgent_words, &String.contains?(text, &1)) do
      ["urgent" | tags]
    else
      tags
    end
  end
end
```
