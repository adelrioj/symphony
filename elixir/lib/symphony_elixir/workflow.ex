defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.LaneContext

  @workflow_file_name "WORKFLOW.md"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    with {:ok, entry} <- LaneContext.capture() do
      case entry.workflow do
        nil -> {:error, {:lane_invalid, entry.error}}
        workflow -> {:ok, workflow}
      end
    end
  end

  @doc "Renders the pinned attempt workflow, or the current lane version outside an attempt."
  @spec current_content() :: {:ok, String.t()} | {:error, term()}
  def current_content do
    with {:ok, entry} <- LaneContext.capture() do
      if is_binary(entry.front_matter) do
        {:ok, render(entry.front_matter, entry.prompt)}
      else
        {:error, {:lane_invalid, entry.error}}
      end
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @doc """
  Splits a workflow into raw YAML and prompt text without normalizing either section.

  Delimiter lines and their adjacent line breaks are not part of the returned text.
  The two strings do not retain envelope metadata: CRLF delimiters, an empty front
  matter block, a closing delimiter at EOF, and an unterminated block cannot all be
  distinguished from their canonical LF or prompt-only equivalents by `render/2`.
  """
  @spec split(String.t()) :: %{front_matter: String.t(), prompt: String.t()}
  def split(content) when is_binary(content) do
    case Regex.run(~r/\A---(?:\R|\z)/u, content, return: :index) do
      [{0, opening_size}] ->
        tail = binary_part(content, opening_size, byte_size(content) - opening_size)
        split_front_matter(tail)

      nil ->
        %{front_matter: "", prompt: content}
    end
  end

  @doc """
  Renders ordinary YAML and prompt strings using LF-delimited front matter.

  Empty YAML renders as a prompt-only file. `split/1` round-trips byte for byte for
  nonempty front matter enclosed by LF delimiter lines with a newline after the
  closing delimiter, and for prompt-only files. Other envelopes are canonicalized;
  leading blank lines in YAML remain content, never hidden envelope metadata.
  """
  @spec render(String.t(), String.t()) :: String.t()
  def render("", prompt) when is_binary(prompt), do: prompt
  def render(front_matter, prompt) when is_binary(front_matter) and is_binary(prompt), do: "---\n" <> front_matter <> "\n---\n" <> prompt

  @doc """
  Strip controller-only configuration from a snapshot before it is shipped to a worker.

  `worker.environment` describes how the controller provisions the worker and points at
  controller-local paths — `provider.kubeconfig` above all. A guest cannot satisfy them,
  and the tracker MCP server refuses to start on a workflow whose provider block it
  cannot resolve, which leaves the agent without the approval channel it was told to
  use. The worker has no business knowing how it was provisioned either.
  """
  @spec for_worker(String.t()) :: String.t()
  def for_worker(content) when is_binary(content) do
    %{front_matter: front_matter, prompt: prompt} = split(content)

    case front_matter_yaml_to_map(String.replace(front_matter, ~r/\R/u, "\n")) do
      {:ok, %{"worker" => %{"environment" => _} = worker} = config} ->
        worker = Map.delete(worker, "environment")
        config = if worker == %{}, do: Map.delete(config, "worker"), else: Map.put(config, "worker", worker)
        render(Jason.encode!(config), prompt)

      _ ->
        content
    end
  end

  @spec parse(String.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse(content) when is_binary(content) do
    %{front_matter: front_matter, prompt: prompt} = split(content)
    parse_parts(front_matter, prompt)
  end

  @spec parse_parts(String.t(), String.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse_parts(front_matter, prompt) when is_binary(front_matter) and is_binary(prompt) do
    case front_matter_yaml_to_map(String.replace(front_matter, ~r/\R/u, "\n")) do
      {:ok, config} ->
        trimmed = prompt |> String.replace(~r/\R/u, "\n") |> String.trim()
        {:ok, %{config: config, prompt: trimmed, prompt_template: trimmed}}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(tail) do
    case Regex.run(~r/(?:\A|\R)---(?=\R|\z)/u, tail, return: :index) do
      [{offset, delimiter_size}] ->
        after_delimiter = offset + delimiter_size
        rest = binary_part(tail, after_delimiter, byte_size(tail) - after_delimiter)

        prompt =
          case Regex.run(~r/\A\R/u, rest, return: :index) do
            [{0, newline_size}] -> binary_part(rest, newline_size, byte_size(rest) - newline_size)
            nil -> rest
          end

        %{front_matter: binary_part(tail, 0, offset), prompt: prompt}

      nil ->
        %{front_matter: tail, prompt: ""}
    end
  end

  defp front_matter_yaml_to_map(yaml) when is_binary(yaml) do
    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
