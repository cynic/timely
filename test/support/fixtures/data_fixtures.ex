defmodule Timely.DataFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Timely.Data` context.
  """

  @doc """
  Generate a checklist_item.
  """
  def checklist_item_fixture(attrs \\ %{}) do
    {:ok, checklist_item} =
      attrs
      |> Enum.into(%{
        description: "some description"
      })
      |> Timely.Data.create_checklist_item()

    checklist_item
  end

  @doc """
  Generate a task.
  """
  def task_fixture(attrs \\ %{}) do
    {:ok, task} =
      attrs
      |> Enum.into(%{
        status: :active,
        text: "some text"
      })
      |> Timely.Data.create_task()

    task
  end

  @doc """
  Generate a comment.
  """
  def comment_fixture(attrs \\ %{}) do
    {:ok, comment} =
      attrs
      |> Enum.into(%{
        comment_reason: :justify_ignored,
        text: "some text"
      })
      |> Timely.Data.create_comment()

    comment
  end
end
