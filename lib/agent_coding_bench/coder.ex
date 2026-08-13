defmodule AgentCodingBench.Coder do
  @moduledoc """
  Bench-owned boundary around the opencode client used by Coder sessions.

  The wrapper deliberately exposes only the operations the world needs so the
  generated SDK can be replaced with direct Req calls without changing lanes.
  """

  alias AgentCodingBench.Box
  alias OpenCode.Generated.Operations

  @typedoc "An opencode client scoped to one clone, or to the server event feed."
  @opaque client :: keyword()

  @type result(value) :: {:ok, value} | {:error, term()}
  @type permission_reply :: :once | :always | :reject

  @callback client(String.t() | nil) :: term()
  @callback create_session(term(), map()) :: result(map())
  @callback prompt_async(term(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback abort_session(term(), String.t()) :: result(boolean())
  @callback reply_question(term(), String.t(), [[String.t()]]) :: result(boolean())
  @callback reply_permission(term(), String.t(), permission_reply()) :: result(boolean())
  @callback event_stream(term()) :: result(Enumerable.t())
  @callback pending_questions(term()) :: result([map()])
  @callback pending_permissions(term()) :: result([map()])

  @doc """
  Builds a client for a clone directory.

  Passing `nil` as the directory builds the server-wide client used by the
  EventRelay. `:base_url` is available for focused integration checks.
  """
  @spec client(String.t() | nil, keyword()) :: client()
  def client(directory, opts \\ []) when is_binary(directory) or is_nil(directory) do
    base_url = Keyword.get(opts, :base_url, Box.opencode_url())
    OpenCode.create_client(base_url: base_url, directory: directory)
  end

  @doc "Creates a Coder session in the client's clone."
  @spec create_session(client(), map()) :: result(map())
  def create_session(client, attrs \\ %{}) when is_map(attrs) do
    Operations.session_create(attrs, client)
  end

  @doc "Sends text to a Coder session without waiting for the tool loop to finish."
  @spec prompt_async(client(), String.t(), String.t()) :: :ok | {:error, term()}
  def prompt_async(client, session_id, prompt)
      when is_binary(session_id) and is_binary(prompt) do
    Operations.session_prompt_async(
      session_id,
      %{parts: [%{type: "text", text: prompt}]},
      client
    )
  end

  @doc "Aborts an active Coder session."
  @spec abort_session(client(), String.t()) :: result(boolean())
  def abort_session(client, session_id) when is_binary(session_id) do
    Operations.session_abort(session_id, client)
  end

  @doc "Replies to all prompts in a pending opencode question request."
  @spec reply_question(client(), String.t(), [[String.t()]]) :: result(boolean())
  def reply_question(client, request_id, answers)
      when is_binary(request_id) and is_list(answers) do
    Operations.question_reply(request_id, %{answers: answers}, client)
  end

  @doc "Replies to a pending opencode permission request."
  @spec reply_permission(client(), String.t(), permission_reply()) :: result(boolean())
  def reply_permission(client, request_id, reply)
      when is_binary(request_id) and reply in [:once, :always, :reject] do
    Operations.permission_reply(request_id, %{reply: Atom.to_string(reply)}, client)
  end

  @doc "Subscribes to the server event feed."
  @spec event_stream(client()) :: result(Enumerable.t())
  def event_stream(client) do
    case Operations.event_subscribe(client) do
      {:ok, %{stream: stream}} -> {:ok, stream}
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc "Lists question requests that remain unanswered."
  @spec pending_questions(client()) :: result([map()])
  def pending_questions(client), do: Operations.question_list(client)

  @doc "Lists permission requests that remain unanswered."
  @spec pending_permissions(client()) :: result([map()])
  def pending_permissions(client), do: Operations.permission_list(client)
end
