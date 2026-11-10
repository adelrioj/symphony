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

  @label_policy_keys [:required_labels, :any_labels, :excluded_labels]

  @doc "The tracker settings keys that make up the label policy read by `routable?/2`."
  @spec label_policy_keys() :: [atom()]
  def label_policy_keys, do: @label_policy_keys

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @doc """
  Whether the issue may be dispatched or kept running under a label policy.

  `label_policy` is any map with optional `:required_labels` (every label must
  match), `:any_labels` (at least one label must match) and `:excluded_labels`
  (no label may match) entries. An empty or absent list imposes no constraint.
  Matching ignores case and surrounding whitespace, so a blank configured label
  matches no issue. A `label_policy` that is not a map raises rather than
  reporting the issue as unroutable.
  """
  @spec routable?(t(), map()) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels} = issue, label_policy)
      when is_list(labels) and is_map(label_policy) do
    issue_labels = MapSet.new(labels, &normalize_label/1)

    required_labels = Map.get(label_policy, :required_labels) || []
    any_labels = Map.get(label_policy, :any_labels) || []

    is_nil(excluded_label(issue, label_policy)) and
      Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1))) and
      any_label_satisfied?(any_labels, issue_labels)
  end

  def routable?(%__MODULE__{}, label_policy) when is_map(label_policy), do: false

  @doc """
  The first configured `:excluded_labels` entry this issue carries, or `nil`.

  This is an affirmative observation of the issue's own labels, independent of
  `dispatchable`: callers use it to remove an issue from a lane completely, so it
  must only ever be applied to an issue returned by a successful tracker read.
  A blank configured label matches no issue.
  """
  @spec excluded_label(t(), map()) :: String.t() | nil
  def excluded_label(%__MODULE__{labels: labels}, label_policy) when is_list(labels) and is_map(label_policy) do
    issue_labels = MapSet.new(labels, &normalize_label/1)

    (Map.get(label_policy, :excluded_labels) || [])
    |> Enum.map(&normalize_label/1)
    |> Enum.find(&(&1 != "" and MapSet.member?(issue_labels, &1)))
  end

  def excluded_label(%__MODULE__{}, label_policy) when is_map(label_policy), do: nil

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
