defmodule AgentCodingBench.World.Cast do
  @moduledoc """
  Prompt assembly and output contracts for the PM, Reviewer, and Person.

  This module contains no lane state. Callers provide the task-scoped facts,
  while `AgentCodingBench.Cast` owns the actual completion and observation.
  """

  alias AgentCodingBench.Cast, as: Completion

  @type task_invention :: %{
          title: String.t(),
          description: String.t(),
          persona_card: persona_card()
        }
  @type persona_card :: %{
          name: String.t(),
          role: String.t(),
          communication_style: String.t(),
          pickiness: String.t()
        }

  @sizes [:small, :medium, :large]

  @doc "Returns the task sizes the PM can be asked for."
  @spec sizes() :: [atom()]
  def sizes, do: @sizes

  @doc """
  Invents a task for the mechanically assigned World Repo and its Persona Card.

  Both the World Repo and the size are assigned by the rig, so the PM shapes the
  work but never picks how much of it there is.
  """
  @spec invent_task(non_neg_integer(), String.t(), String.t(), atom(), keyword()) ::
          {:ok, task_invention()} | {:error, term()}
  def invent_task(lane, world_repo, digest, size, opts \\ [])
      when is_integer(lane) and lane >= 0 and is_binary(world_repo) and is_binary(digest) and
             size in @sizes do
    cast = Keyword.get(opts, :cast, Completion)

    pm_messages = [
      %{role: "system", content: prompt!("pm.md") <> "\n\n" <> prompt!("task-size-#{size}.md")},
      %{
        role: "user",
        content: "World Repo: #{world_repo}\n\nClone digest:\n#{digest}"
      }
    ]

    with {:ok, content} <-
           cast.complete(
             pm_messages,
             %{lane: lane, role: :pm},
             completion_opts(opts, task_schema())
           ),
         {:ok, task} <- decode_fields(content, [:title, :description]),
         {:ok, persona_card} <- generate_persona(cast, lane, task, opts) do
      {:ok, Map.put(task, :persona_card, persona_card)}
    end
  end

  @doc "Returns a fresh, diff-only prose review for one task pass."
  @spec review_task(non_neg_integer(), integer(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def review_task(lane, task_id, task, diff, opts \\ [])
      when is_integer(lane) and lane >= 0 and is_integer(task_id) and is_map(task) and
             is_binary(diff) do
    cast = Keyword.get(opts, :cast, Completion)
    diff = truncate_diff(diff, diff_char_cap(opts))

    messages = [
      %{role: "system", content: prompt!("reviewer.md")},
      %{
        role: "user",
        content: "#{task_text(task)}\n\nDiff:\n#{diff}"
      }
    ]

    cast.complete(
      messages,
      %{lane: lane, role: :reviewer, task_id: task_id},
      Keyword.get(opts, :cast_opts, [])
    )
  end

  @doc "Answers one Coder question as the task's Person."
  @spec answer_question(
          non_neg_integer(),
          integer(),
          map(),
          map(),
          [map()],
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def answer_question(lane, task_id, task, persona_card, transcript, question, opts \\ [])
      when is_integer(lane) and lane >= 0 and is_integer(task_id) and is_map(task) and
             is_map(persona_card) and is_list(transcript) and is_binary(question) do
    cast = Keyword.get(opts, :cast, Completion)

    messages = [
      %{role: "system", content: prompt!("person.md")},
      %{
        role: "user",
        content:
          person_context(task, persona_card, transcript) <>
            "\n\nCoder question:\n#{question}\n\nAnswer the question as this Person."
      }
    ]

    cast.complete(
      messages,
      %{lane: lane, role: :person, task_id: task_id},
      Keyword.get(opts, :cast_opts, [])
    )
  end

  @doc "Rules merge or rework from the review as the task's Person."
  @spec decide(
          non_neg_integer(),
          integer(),
          map(),
          map(),
          [map()],
          String.t(),
          keyword()
        ) :: {:ok, %{decision: String.t(), feedback: String.t()}} | {:error, term()}
  def decide(lane, task_id, task, persona_card, transcript, review, opts \\ [])
      when is_integer(lane) and lane >= 0 and is_integer(task_id) and is_map(task) and
             is_map(persona_card) and is_list(transcript) and is_binary(review) do
    cast = Keyword.get(opts, :cast, Completion)

    messages = [
      %{role: "system", content: prompt!("person.md")},
      %{
        role: "user",
        content:
          person_context(task, persona_card, transcript) <>
            "\n\nReviewer's review:\n#{review}\n\nRule whether to merge as-is or return it for rework."
      }
    ]

    with {:ok, content} <-
           cast.complete(
             messages,
             %{lane: lane, role: :person, task_id: task_id},
             completion_opts(opts, decision_schema())
           ),
         {:ok, result} <- decode_fields(content, [:decision, :feedback]),
         true <- result.decision in ["merge", "rework"] do
      {:ok, result}
    else
      false -> {:error, {:invalid_cast_field, :decision}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_persona(cast, lane, task, opts) do
    messages = [
      %{role: "system", content: prompt!("persona.md")},
      %{
        role: "user",
        content: "Task: #{task.title}\n\n#{task.description}"
      }
    ]

    with {:ok, content} <-
           cast.complete(
             messages,
             %{lane: lane, role: :person},
             completion_opts(opts, persona_schema())
           ) do
      decode_fields(content, [:name, :role, :communication_style, :pickiness])
    end
  end

  defp completion_opts(opts, response_format) do
    opts
    |> Keyword.get(:cast_opts, [])
    |> Keyword.put(:response_format, response_format)
  end

  defp task_text(%{title: title, description: description})
       when is_binary(title) and is_binary(description) do
    "Task: #{title}\n\n#{description}"
  end

  defp task_text(%{"title" => title, "description" => description})
       when is_binary(title) and is_binary(description) do
    "Task: #{title}\n\n#{description}"
  end

  defp person_context(task, persona_card, transcript) do
    """
    Persona Card:
    #{Jason.encode!(persona_card, pretty: true)}

    #{task_text(task)}

    Task-scoped transcript:
    #{transcript_text(transcript)}
    """
    |> String.trim()
  end

  defp transcript_text([]), do: "(none)"

  defp transcript_text(events) do
    Enum.map_join(events, "\n", fn
      %{kind: kind, content: content} when is_binary(content) -> "#{kind}: #{content}"
      %{"kind" => kind, "content" => content} when is_binary(content) -> "#{kind}: #{content}"
    end)
  end

  defp truncate_diff(diff, cap) do
    if String.length(diff) > cap do
      String.slice(diff, 0, cap) <> "\n\n[diff truncated at #{cap} characters]"
    else
      diff
    end
  end

  defp diff_char_cap(opts) do
    configured =
      :agent_coding_bench
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:diff_char_cap, 60_000)

    Keyword.get(opts, :diff_char_cap, configured)
  end

  defp decode_fields(content, fields) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(content),
         {:ok, values} <- fetch_strings(decoded, fields) do
      {:ok, Map.new(Enum.zip(fields, values))}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_cast_json, error}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_cast_output, content}}
    end
  end

  defp fetch_strings(decoded, fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, values} ->
      case Map.get(decoded, Atom.to_string(field)) do
        value when is_binary(value) and value != "" -> {:cont, {:ok, [value | values]}}
        _ -> {:halt, {:error, {:invalid_cast_field, field}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp prompt!(filename) do
    :agent_coding_bench
    |> Application.app_dir("priv/prompts/#{filename}")
    |> File.read!()
    |> String.trim()
  end

  defp json_schema(name, properties) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "strict" => true,
        "schema" => %{
          "type" => "object",
          "properties" => properties,
          "required" => Map.keys(properties),
          "additionalProperties" => false
        }
      }
    }
  end

  defp task_schema do
    json_schema("task", %{
      "title" => string_schema(),
      "description" => string_schema()
    })
  end

  defp persona_schema do
    json_schema("persona_card", %{
      "name" => string_schema(),
      "role" => string_schema(),
      "communication_style" => string_schema(),
      "pickiness" => string_schema()
    })
  end

  defp decision_schema do
    json_schema("person_decision", %{
      "decision" => %{"type" => "string", "enum" => ["merge", "rework"]},
      "feedback" => string_schema()
    })
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1}
end
