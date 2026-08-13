defmodule AgentCodingBench.World.CastTest do
  use ExUnit.Case, async: true

  alias AgentCodingBench.CastFake
  alias AgentCodingBench.World.Cast

  test "invents a task for the assigned World Repo and generates its Persona Card" do
    CastFake.put_completions([
      {:ok,
       Jason.encode!(%{
         title: "Expose parser diagnostics",
         description: "Return line-aware diagnostics so configuration errors are actionable."
       })},
      {:ok,
       Jason.encode!(%{
         name: "Rina Patel",
         role: "maintainer",
         communication_style: "brief and direct",
         pickiness: "cares strongly about error-message clarity"
       })}
    ])

    assert {:ok, task} =
             Cast.invent_task(2, "nimble_parsec", "## File tree\nlib/parser.ex", cast: CastFake)

    assert task.title == "Expose parser diagnostics"
    assert task.description =~ "line-aware diagnostics"
    assert task.persona_card.name == "Rina Patel"
    assert task.persona_card.pickiness =~ "error-message clarity"

    assert_received {:cast_completion, pm_messages, %{lane: 2, role: :pm}, pm_opts}
    assert messages_text(pm_messages) =~ "nimble_parsec"
    assert messages_text(pm_messages) =~ "lib/parser.ex"
    assert pm_opts[:response_format]["type"] == "json_schema"

    assert_received {:cast_completion, persona_messages, %{lane: 2, role: :person}, persona_opts}
    assert messages_text(persona_messages) =~ "Expose parser diagnostics"
    assert persona_opts[:response_format]["type"] == "json_schema"
  end

  test "reviews only the task and a hard-capped diff, returning prose without a verdict" do
    CastFake.put_completions([
      {:ok, "The change is focused. The new branch lacks coverage for malformed input."}
    ])

    task = %{
      title: "Expose parser diagnostics",
      description: "Return line-aware diagnostics for invalid configuration."
    }

    diff = "0123456789abcdefghijTHIS-MUST-BE-TRUNCATED"

    assert {:ok, review} =
             Cast.review_task(3, 44, task, diff,
               cast: CastFake,
               diff_char_cap: 20
             )

    assert review =~ "lacks coverage"

    assert_received {:cast_completion, messages, %{lane: 3, role: :reviewer, task_id: 44}, opts}
    prompt = messages_text(messages)
    assert prompt =~ task.title
    assert prompt =~ "0123456789abcdefghij"
    assert prompt =~ "[diff truncated at 20 characters]"
    refute prompt =~ "THIS-MUST-BE-TRUNCATED"
    refute Keyword.has_key?(opts, :response_format)
  end

  test "Person answers and decides from one Persona Card and the task-scoped transcript" do
    CastFake.put_completions([
      {:ok, "Use byte offsets, but include the source line in the rendered diagnostic."},
      {:ok, Jason.encode!(%{decision: "rework", feedback: "Add the missing source line."})}
    ])

    task = %{title: "Expose parser diagnostics", description: "Make failures actionable."}

    card = %{
      name: "Rina Patel",
      role: "maintainer",
      communication_style: "brief and direct",
      pickiness: "cares strongly about error-message clarity"
    }

    transcript = [
      %{kind: :question, content: "Should locations use bytes or code points?"},
      %{kind: :answer, content: "Use byte offsets."}
    ]

    assert {:ok, answer} =
             Cast.answer_question(
               3,
               44,
               task,
               card,
               transcript,
               "Should the diagnostic show source text?",
               cast: CastFake
             )

    assert answer =~ "include the source line"

    assert_received {:cast_completion, answer_messages, %{role: :person, task_id: 44},
                     answer_opts}

    answer_prompt = messages_text(answer_messages)
    assert answer_prompt =~ "Rina Patel"
    assert answer_prompt =~ "Use byte offsets."
    assert answer_prompt =~ "Should the diagnostic show source text?"
    refute Keyword.has_key?(answer_opts, :response_format)

    assert {:ok, %{decision: "rework", feedback: "Add the missing source line."}} =
             Cast.decide(3, 44, task, card, transcript, "The source line is missing.",
               cast: CastFake
             )

    assert_received {:cast_completion, decision_messages, %{role: :person, task_id: 44},
                     decision_opts}

    decision_prompt = messages_text(decision_messages)
    assert decision_prompt =~ "Rina Patel"
    assert decision_prompt =~ "The source line is missing."
    assert decision_prompt =~ "Use byte offsets."

    decision_schema = decision_opts[:response_format]["json_schema"]["schema"]
    assert decision_schema["properties"]["decision"]["enum"] == ["merge", "rework"]
  end

  defp messages_text(messages), do: Enum.map_join(messages, "\n", & &1.content)
end
