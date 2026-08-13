defmodule AgentCodingBench.CoderFake do
  @moduledoc false

  @behaviour AgentCodingBench.Coder

  @impl true
  def client(directory), do: directory

  @impl true
  def create_session(test_pid, attrs), do: request(test_pid, :create_session, [attrs])

  @impl true
  def prompt_async(test_pid, session_id, prompt) do
    request(test_pid, :prompt_async, [session_id, prompt])
  end

  @impl true
  def abort_session(test_pid, session_id), do: request(test_pid, :abort_session, [session_id])

  @impl true
  def reply_question(test_pid, request_id, answers) do
    request(test_pid, :reply_question, [request_id, answers])
  end

  @impl true
  def reply_permission(test_pid, request_id, reply) do
    request(test_pid, :reply_permission, [request_id, reply])
  end

  @impl true
  def event_stream(test_pid) do
    send(test_pid, {:event_stream_subscribed, self()})

    stream =
      Stream.repeatedly(fn ->
        receive do
          {:event, event} -> event
          {:fail, reason} -> {:error, reason}
        end
      end)

    {:ok, stream}
  end

  @impl true
  def pending_questions(test_pid), do: request(test_pid, :pending_questions, [])

  @impl true
  def pending_permissions(test_pid), do: request(test_pid, :pending_permissions, [])

  defp request(test_pid, operation, args) do
    ref = make_ref()
    send(test_pid, {:coder_request, operation, args, self(), ref})

    receive do
      {:coder_reply, ^ref, result} -> result
    end
  end
end
