defmodule AgentCodingBench.World.Lane do
  @moduledoc """
  One permanently supervised Task pipeline in the World.

  A Lane serializes invention, coding, review, and the Person's ruling while
  its Coder session receives point-to-point events from `World.EventRelay`.
  """

  use GenServer, restart: :permanent

  alias AgentCodingBench.Coder
  alias AgentCodingBench.World
  alias AgentCodingBench.World.Cast
  alias AgentCodingBench.World.Clone
  alias AgentCodingBench.World.CloneDigest
  alias AgentCodingBench.World.CrashSweep
  alias AgentCodingBench.World.CrashSweeper
  alias AgentCodingBench.World.RepoCycle
  alias AgentCodingBench.World.SessionRegistry
  alias AgentCodingBench.World.SizeCycle
  alias AgentCodingBench.World.Task

  @question_event_types ["question.asked", "question.v2.asked"]
  @pending_event_types ["session.idle", "permission.asked" | @question_event_types]

  @type status :: %{
          lane: non_neg_integer(),
          state: :inventing | :coding | :reviewing | :deciding,
          task_id: integer() | nil,
          task_title: String.t() | nil,
          world_repo: String.t() | nil,
          session_id: String.t() | nil,
          state_started_at: DateTime.t(),
          last_event_at: DateTime.t() | nil,
          last_abandon_reason: atom() | nil
        }

  @doc false
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns the Lane's current observable state."
  @spec status(GenServer.server()) :: status()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    lane = Keyword.fetch!(opts, :lane)
    repos = Keyword.fetch!(opts, :repos)

    state = %{
      lane: lane,
      repos: repos,
      repo_cycle: RepoCycle.new(repos),
      clone_root: Keyword.get(opts, :clone_root, "/root/world/lanes"),
      cast: Keyword.get(opts, :cast, AgentCodingBench.Cast),
      cast_opts: Keyword.get(opts, :cast_opts, []),
      coder: Keyword.get(opts, :coder, Coder),
      coder_client: Keyword.get(opts, :coder_client),
      exec: Keyword.get(opts, :exec, &AgentCodingBench.Box.exec/2),
      registry: Keyword.get(opts, :registry, SessionRegistry),
      pubsub: Keyword.get(opts, :pubsub, AgentCodingBench.PubSub),
      crash_sweeper: Keyword.get(opts, :crash_sweeper, CrashSweeper),
      inactivity_timeout: Keyword.get(opts, :inactivity_timeout, 600_000),
      task_timeout: Keyword.get(opts, :task_timeout, 3_600_000),
      task_timeouts: Keyword.get(opts, :task_timeouts, %{}),
      size_cycle: SizeCycle.new(Keyword.get(opts, :size_weights, small: 10, medium: 7, large: 3)),
      size: nil,
      invention_retry_delay: Keyword.get(opts, :invention_retry_delay, 5_000),
      state: :inventing,
      state_started_at: DateTime.utc_now(),
      last_event_at: nil,
      last_abandon_reason: nil,
      repo: nil,
      clone_path: nil,
      task: nil,
      client: nil,
      session_id: nil,
      operation: nil,
      pending_events: [],
      inactivity_timer: nil,
      inactivity_token: nil,
      task_timer: nil,
      task_token: nil
    }

    {:ok, announce(state), {:continue, :crash_sweep}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_continue(:crash_sweep, state) do
    {:noreply,
     start_operation(state, :crash_sweep, fn ->
       with :ok <- await_global_sweep(state.crash_sweeper) do
         CrashSweep.run(state.lane, state.repos, state.clone_root, state.exec)
       end
     end)}
  end

  def handle_continue(:invent, state) do
    {repo, repo_cycle} = RepoCycle.next(state.repo_cycle)
    {size, size_cycle} = SizeCycle.next(state.size_cycle)
    clone_path = Clone.path(state.lane, clone_directory(repo), state.clone_root)

    # The size is drawn before the timer starts so the cap matches the amount of
    # work being asked for, rather than one global cap guillotining a large task
    # and letting a stuck small one hold the Lane for an hour.
    state =
      announce(%{
        state
        | repo: repo,
          repo_cycle: repo_cycle,
          size: size,
          size_cycle: size_cycle,
          clone_path: clone_path
      })

    state = start_task_timer(state)
    {:noreply, start_operation(state, :invent, fn -> invent_operation(state) end)}
  end

  def handle_continue(:review, state) do
    {:noreply, start_operation(state, :review, fn -> review_operation(state) end)}
  end

  def handle_continue(:decide, state) do
    {:noreply, start_operation(state, :decide, fn -> decide_operation(state) end)}
  end

  @impl true
  def handle_info(
        {:coder_event, %{"type" => "session.error", "properties" => properties}},
        state
      ) do
    if current_session?(state, properties) do
      continue_after_abandon(touch_event(state), :session_error)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:coder_event, %{"type" => type} = event},
        %{operation: operation} = state
      )
      when type in @pending_event_types and not is_nil(operation) do
    if current_session?(state, event["properties"]) do
      state =
        if state.state == :coding do
          state |> touch_event() |> restart_inactivity()
        else
          touch_event(state)
        end

      {:noreply, %{state | pending_events: [event | state.pending_events]}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:coder_event, %{"type" => "session.idle", "properties" => properties}},
        %{state: :coding} = state
      ) do
    if current_session?(state, properties) do
      state = state |> touch_event() |> cancel_inactivity() |> transition(:reviewing)
      {:noreply, state, {:continue, :review}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:coder_event, %{"type" => type, "properties" => properties}},
        %{state: :coding} = state
      )
      when type in @question_event_types do
    if current_session?(state, properties) do
      state = state |> touch_event() |> restart_inactivity()

      {:noreply,
       start_operation(state, :answer_questions, fn ->
         answer_questions_operation(state, properties)
       end)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:coder_event, %{"properties" => properties}}, %{state: :coding} = state) do
    if current_session?(state, properties) do
      {:noreply, state |> touch_event() |> restart_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:inactivity_timeout, token}, %{inactivity_token: token} = state) do
    continue_after_abandon(state, :inactivity_timeout)
  end

  def handle_info({:task_timeout, token}, %{task_token: token, task: %Task{}} = state) do
    continue_after_abandon(state, :task_timeout)
  end

  def handle_info({:task_timeout, token}, %{task_token: token, task: nil} = state) do
    state = state |> cancel_operation() |> cancel_task_timer()
    Process.send_after(self(), :retry_invention, state.invention_retry_delay)
    {:noreply, state}
  end

  def handle_info(
        {:operation_result, operation_ref, result},
        %{operation: %{ref: operation_ref} = operation} = state
      ) do
    Process.demonitor(operation.monitor, [:flush])
    state = state |> Map.put(:operation, nil) |> release_pending_events()
    handle_operation_result(operation.tag, result, state)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{operation: %{monitor: monitor} = operation} = state
      ) do
    state = %{state | operation: nil}

    case {operation.tag, state.task} do
      {:crash_sweep, nil} ->
        Process.send_after(self(), :retry_crash_sweep, state.invention_retry_delay)
        {:noreply, state}

      {_tag, %Task{}} ->
        continue_after_abandon(state, :completion_failure)

      {_tag, nil} ->
        state = cancel_task_timer(state)
        Process.send_after(self(), :retry_invention, state.invention_retry_delay)
        {:noreply, state}
    end
  end

  def handle_info(:retry_crash_sweep, %{state: :inventing, task: nil} = state) do
    {:noreply, state, {:continue, :crash_sweep}}
  end

  def handle_info(:retry_invention, %{state: :inventing, task: nil} = state) do
    {:noreply, state, {:continue, :invent}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp invent_operation(state) do
    with :ok <- Clone.ensure(state.clone_path, state.repo.mirror_path, exec: state.exec),
         titles = World.recent_task_titles(state.lane, state.repo.slug),
         {:ok, digest} <- CloneDigest.capture(state.clone_path, titles, exec: state.exec),
         {:ok, invention} <-
           Cast.invent_task(state.lane, state.repo.slug, digest, state.size,
             cast: state.cast,
             cast_opts: state.cast_opts
           ) do
      {:ok, invention}
    else
      {:error, {:clone_operation, _, _, _} = reason} -> {:error, reason}
      {:error, {:clone_digest, _, _, _} = reason} -> {:error, reason}
      {:error, _completion_reason} -> :completion_error
    end
  end

  defp start_task(state, invention) do
    attrs = %{
      lane: state.lane,
      world_repo: state.repo.slug,
      title: invention.title,
      description: invention.description,
      persona_card: invention.persona_card,
      size: Atom.to_string(state.size)
    }

    with {:ok, task} <- World.create_task(attrs),
         state = %{state | task: task} |> start_task_timer() |> announce() do
      {:ok,
       start_operation(state, :create_session, fn ->
         create_session_operation(state)
       end)}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp create_session_operation(state) do
    client = state.coder_client || state.coder.client(state.clone_path)

    with :ok <-
           Clone.prepare_task(
             state.clone_path,
             state.repo.mirror_path,
             state.task.id,
             exec: state.exec
           ),
         {:ok, session} <- state.coder.create_session(client, %{}),
         {:ok, session_id} <- session_id(session) do
      {:ok, client, session_id}
    else
      {:error, {:clone_operation, _, _, _} = reason} -> {:error, reason}
      _error -> :session_error
    end
  end

  defp review_operation(state) do
    with {:ok, diff} <- Clone.diff(state.clone_path, exec: state.exec),
         {:ok, review} <-
           Cast.review_task(state.lane, state.task.id, state.task, diff,
             cast: state.cast,
             cast_opts: state.cast_opts
           ) do
      {:ok, review}
    else
      {:error, {:clone_operation, _, _, _} = reason} -> {:error, reason}
      {:error, _completion_reason} -> :completion_error
    end
  end

  defp decide_operation(state) do
    transcript = World.transcript(state.task)

    Cast.decide(
      state.lane,
      state.task.id,
      state.task,
      state.task.persona_card,
      transcript,
      state.review,
      cast: state.cast,
      cast_opts: state.cast_opts
    )
  end

  defp answer_questions_operation(state, properties) do
    questions = Map.get(properties, "questions", [])

    result =
      Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, answers} ->
        content = question["question"] || question["text"] || Jason.encode!(question)

        with {:ok, _event} <- World.record_event(state.task, :question, content),
             {:ok, answer} <-
               Cast.answer_question(
                 state.lane,
                 state.task.id,
                 state.task,
                 state.task.persona_card,
                 World.transcript(state.task),
                 content,
                 cast: state.cast,
                 cast_opts: state.cast_opts
               ),
             {:ok, _event} <- World.record_event(state.task, :answer, answer) do
          {:cont, {:ok, [[answer] | answers]}}
        else
          {:error, %Ecto.Changeset{} = changeset} -> {:halt, {:error, changeset}}
          {:error, _reason} -> {:halt, :completion_error}
        end
      end)

    case result do
      {:ok, answers} ->
        case state.coder.reply_question(
               state.client,
               properties["id"],
               Enum.reverse(answers)
             ) do
          {:ok, _accepted} -> :ok
          _error -> :session_error
        end

      :completion_error ->
        :completion_error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_after_abandon(state, reason) do
    case abandon_result(state, reason) do
      {:ok, state} -> {:noreply, state, {:continue, :invent}}
      {:error, error} -> {:stop, error, state}
    end
  end

  defp abandon_result(state, reason) do
    if state.session_id do
      _ = state.coder.abort_session(state.client, state.session_id)
    end

    with :ok <- Clone.reset(state.clone_path, exec: state.exec),
         {:ok, _task} <- World.abandon_task(state.task, reason) do
      {:ok, finish_cycle(state, reason)}
    end
  end

  defp finish_cycle(state, reason \\ nil) do
    state
    |> cancel_operation()
    |> cancel_inactivity()
    |> cancel_task_timer()
    |> unregister_session()
    |> Map.merge(%{
      task: nil,
      client: nil,
      session_id: nil,
      review: nil,
      pending_events: [],
      last_abandon_reason: reason
    })
    |> transition(:inventing)
  end

  defp session_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp session_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp session_id(session), do: {:error, {:invalid_session, session}}

  defp current_session?(state, properties) do
    state.session_id != nil and properties["sessionID"] == state.session_id
  end

  defp transition(state, next_state) do
    announce(%{state | state: next_state, state_started_at: DateTime.utc_now()})
  end

  defp touch_event(state), do: announce(%{state | last_event_at: DateTime.utc_now()})

  defp restart_inactivity(state) do
    state = cancel_inactivity(state)

    token = make_ref()
    ref = Process.send_after(self(), {:inactivity_timeout, token}, state.inactivity_timeout)

    %{state | inactivity_timer: ref, inactivity_token: token}
  end

  defp start_task_timer(%{task_timer: nil} = state) do
    token = make_ref()
    ref = Process.send_after(self(), {:task_timeout, token}, task_timeout(state))
    %{state | task_timer: ref, task_token: token}
  end

  defp start_task_timer(state), do: state

  # `task_timeout` stays the fallback so a Lane configured without a per-size map
  # keeps one cap for every size.
  defp task_timeout(state) do
    Map.get(state.task_timeouts, state.size, state.task_timeout)
  end

  defp cancel_inactivity(%{inactivity_timer: nil} = state), do: state

  defp cancel_inactivity(state) do
    Process.cancel_timer(state.inactivity_timer)
    %{state | inactivity_timer: nil, inactivity_token: nil}
  end

  defp cancel_task_timer(%{task_timer: nil} = state), do: state

  defp cancel_task_timer(state) do
    Process.cancel_timer(state.task_timer)
    %{state | task_timer: nil, task_token: nil}
  end

  defp unregister_session(%{session_id: nil} = state), do: state

  defp unregister_session(state) do
    Registry.unregister(state.registry, state.session_id)
    state
  end

  defp announce(state) do
    if state.pubsub do
      Phoenix.PubSub.broadcast(state.pubsub, "world", {:lane_status, public_status(state)})
    end

    state
  end

  defp public_status(state) do
    %{
      lane: state.lane,
      state: state.state,
      task_id: state.task && state.task.id,
      task_title: state.task && state.task.title,
      world_repo: state.repo && state.repo.slug,
      session_id: state.session_id,
      state_started_at: state.state_started_at,
      last_event_at: state.last_event_at,
      last_abandon_reason: state.last_abandon_reason
    }
  end

  defp clone_directory(repo), do: Map.get(repo, :clone_directory, repo.slug)

  defp start_operation(%{operation: nil} = state, tag, operation) do
    parent = self()
    operation_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:operation_result, operation_ref, operation.()})
      end)

    %{state | operation: %{tag: tag, ref: operation_ref, monitor: monitor, pid: pid}}
  end

  defp handle_operation_result(:review, {:ok, review}, state) do
    case World.record_event(state.task, :review, review) do
      {:ok, _event} ->
        state = state |> Map.put(:review, review) |> transition(:deciding)
        {:noreply, state, {:continue, :decide}}

      {:error, changeset} ->
        {:stop, changeset, state}
    end
  end

  defp handle_operation_result(:crash_sweep, :ok, state) do
    {:noreply, state, {:continue, :invent}}
  end

  defp handle_operation_result(:crash_sweep, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp handle_operation_result(:invent, {:ok, invention}, state) do
    case start_task(state, invention) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp handle_operation_result(:invent, :completion_error, state) do
    state = cancel_task_timer(state)
    Process.send_after(self(), :retry_invention, state.invention_retry_delay)
    {:noreply, state}
  end

  defp handle_operation_result(:invent, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp handle_operation_result(:create_session, {:ok, client, session_id}, state) do
    case Registry.register(state.registry, session_id, state.lane) do
      {:ok, _registry_value} ->
        state = %{state | client: client, session_id: session_id}

        {:noreply,
         start_operation(state, :opening_prompt, fn ->
           state.coder.prompt_async(client, session_id, state.task.description)
         end)}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp handle_operation_result(:create_session, :session_error, state) do
    continue_after_abandon(state, :session_error)
  end

  defp handle_operation_result(:create_session, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp handle_operation_result(:opening_prompt, :ok, state) do
    state = state |> transition(:coding) |> touch_event() |> restart_inactivity()
    {:noreply, state}
  end

  defp handle_operation_result(:opening_prompt, _error, state) do
    continue_after_abandon(state, :session_error)
  end

  defp handle_operation_result(:review, :completion_error, state) do
    continue_after_abandon(state, :completion_failure)
  end

  defp handle_operation_result(:review, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp handle_operation_result(:decide, {:ok, %{decision: "merge"}}, state) do
    case World.record_event(state.task, :ruling, "merge") do
      {:ok, _event} ->
        {:noreply,
         start_operation(state, :merge, fn ->
           Clone.merge(state.clone_path, state.task.id, state.task.title, exec: state.exec)
         end)}

      {:error, changeset} ->
        {:stop, changeset, state}
    end
  end

  defp handle_operation_result(
         :decide,
         {:ok, %{decision: "rework", feedback: feedback}},
         state
       ) do
    with {:ok, _ruling} <- World.record_event(state.task, :ruling, "rework"),
         {:ok, _feedback} <- World.record_event(state.task, :feedback, feedback) do
      {:noreply,
       start_operation(state, :rework_prompt, fn ->
         state.coder.prompt_async(state.client, state.session_id, feedback)
       end)}
    else
      {:error, changeset} -> {:stop, changeset, state}
    end
  end

  defp handle_operation_result(:decide, {:error, _reason}, state) do
    continue_after_abandon(state, :completion_failure)
  end

  defp handle_operation_result(:merge, :ok, state) do
    case World.finish_task(state.task) do
      {:ok, _task} -> {:noreply, finish_cycle(state), {:continue, :invent}}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp handle_operation_result(:merge, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp handle_operation_result(:rework_prompt, :ok, state) do
    state = state |> transition(:coding) |> touch_event() |> restart_inactivity()
    {:noreply, state}
  end

  defp handle_operation_result(:rework_prompt, _error, state) do
    continue_after_abandon(state, :session_error)
  end

  defp handle_operation_result(:answer_questions, :ok, state) do
    {:noreply, restart_inactivity(state)}
  end

  defp handle_operation_result(:answer_questions, :completion_error, state) do
    continue_after_abandon(state, :completion_failure)
  end

  defp handle_operation_result(:answer_questions, :session_error, state) do
    continue_after_abandon(state, :session_error)
  end

  defp handle_operation_result(:answer_questions, {:error, reason}, state) do
    {:stop, reason, state}
  end

  defp cancel_operation(%{operation: nil} = state), do: state

  defp cancel_operation(state) do
    Process.exit(state.operation.pid, :kill)
    Process.demonitor(state.operation.monitor, [:flush])
    %{state | operation: nil}
  end

  defp release_pending_events(state) do
    state.pending_events
    |> Enum.reverse()
    |> Enum.each(&send(self(), {:coder_event, &1}))

    %{state | pending_events: []}
  end

  defp await_global_sweep(false), do: :ok
  defp await_global_sweep(server), do: CrashSweeper.await_ready(server)
end
