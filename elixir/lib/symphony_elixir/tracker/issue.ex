defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `identifier` remains the human-readable
  value used to derive the workspace key and must be unique within that scope.
  `attachments` carries non-secret file metadata (`title`, `url`) for the agent;
  the URLs are downloaded through a provider-native tool, never with a token on
  this struct.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    attachments: [],
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          attachments: [map()],
          blocked_by: [map()],
          dispatchable: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec routable?(t(), map()) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels}, label_policy)
      when is_list(labels) and is_map(label_policy) do
    issue_labels = MapSet.new(labels, &normalize_label/1)

    required_labels = Map.get(label_policy, :required_labels) || []
    any_labels = Map.get(label_policy, :any_labels) || []

    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1))) and
      any_label_satisfied?(any_labels, issue_labels)
  end

  def routable?(%__MODULE__{}, _label_policy), do: false

  defp any_label_satisfied?([], _issue_labels), do: true

  defp any_label_satisfied?(any_labels, issue_labels) when is_list(any_labels) do
    Enum.any?(any_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
