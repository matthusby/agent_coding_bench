defmodule AgentCodingBench.World.TaskEvent do
  @moduledoc """
  One append-only interaction in a Task's Person-facing transcript.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias AgentCodingBench.World.Task

  @type t :: %__MODULE__{
          id: integer() | nil,
          task_id: integer() | nil,
          kind: String.t() | nil,
          content: String.t() | nil,
          at: DateTime.t() | nil
        }

  schema "task_events" do
    belongs_to :task, Task
    field :kind, :string
    field :content, :string
    field :at, :utc_datetime_usec
  end

  @doc false
  def changeset(task, kind, content, at) do
    %__MODULE__{task_id: task.id, kind: kind, content: content, at: at}
    |> change()
    |> validate_required([:task_id, :kind, :content, :at])
    |> validate_inclusion(:kind, ~w(question answer review ruling feedback))
  end
end
