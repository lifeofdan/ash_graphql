defmodule AshGraphql.TransactionTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn ->
      AshGraphql.TestHelpers.stop_ets()
    end)
  end

  @tag :focus
  test "transactions return correctly" do
    post_1 =
      AshGraphql.Test.Post
      |> Ash.Changeset.for_create(:create, text: "foo", published: false)
      |> Ash.create!()

    post_2 =
      AshGraphql.Test.Post
      |> Ash.Changeset.for_create(:create, text: "bar", published: false)
      |> Ash.create!()

    {:ok, %{errors: errors}} =
      """
      mutation PublishManyPosts($input: PublishManyPostsInput) {
        publishManyPosts(input: $input)
      }
      """
      |> Absinthe.run(AshGraphql.Test.Schema,
        variables: %{"input" => %{"post_ids" => [post_2.id, post_2.id]}}
      )

    assert Enum.empty?(errors)
  end
end
