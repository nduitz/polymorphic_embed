# Regression tests for inserts, forms and load options. A review of the
# change that keeps the child changesets in the changes found these flows.
defmodule PolymorphicEmbed.ReviewRegressionTest do
  use ExUnit.Case

  alias Ecto.Changeset
  alias PolymorphicEmbed.HTML.Helpers
  alias PolymorphicEmbed.Repo

  alias __MODULE__.{A, B, Holder, Inner, Parent, Wrapper}

  defmodule A do
    use Ecto.Schema

    embedded_schema do
      field :name, :string
    end

    def changeset(struct, params), do: Changeset.cast(struct, params, [:name])

    def required_changeset(struct, params) do
      struct
      |> Changeset.cast(params, [:name])
      |> Changeset.validate_required([:name])
    end

    def failing_prepare_changeset(struct, params) do
      struct
      |> changeset(params)
      |> Changeset.prepare_changes(&Changeset.add_error(&1, :name, "is rejected"))
    end
  end

  defmodule B do
    use Ecto.Schema

    embedded_schema do
      field :name, :string
    end

    def changeset(struct, params), do: Changeset.cast(struct, params, [:name])
  end

  # An ordinary Ecto embed with a polymorphic field.
  defmodule Inner do
    use Ecto.Schema
    import PolymorphicEmbed

    embedded_schema do
      polymorphic_embeds_one :leaf, types: [a: A], on_replace: :update
    end

    def changeset(struct, params) do
      struct
      |> Changeset.cast(params, [])
      |> cast_polymorphic_embed(:leaf)
    end
  end

  # An embedded schema with a field and a polymorphic field. The tests use it
  # as an ordinary Ecto embed and as a polymorphic type.
  defmodule Holder do
    use Ecto.Schema
    import PolymorphicEmbed

    embedded_schema do
      field :name, :string
      polymorphic_embeds_one :leaf, types: [a: A], on_replace: :update
    end

    def changeset(struct, params) do
      struct
      |> Changeset.cast(params, [:name])
      |> cast_polymorphic_embed(:leaf)
    end
  end

  # A polymorphic child with ordinary Ecto embeds.
  defmodule Wrapper do
    use Ecto.Schema

    embedded_schema do
      embeds_one :inner, Inner
      embeds_one :holder, Holder
    end

    def changeset(struct, params) do
      struct
      |> Changeset.cast(params, [])
      |> Changeset.cast_embed(:inner)
      |> Changeset.cast_embed(:holder)
    end
  end

  defmodule Parent do
    use Ecto.Schema
    import PolymorphicEmbed

    schema "reminders" do
      field :date, :utc_datetime
      field :text, :string

      polymorphic_embeds_one :channel,
        types: [a: A, b: B, wrapper: Wrapper, holder: Holder],
        on_replace: :update

      polymorphic_embeds_many :contexts, types: [a: A, b: B], on_replace: :delete

      polymorphic_embeds_many :contexts2,
        types: [a: A],
        retain_unlisted_types_on_load: [:old],
        on_replace: :delete

      polymorphic_embeds_many :contexts3,
        types: [a: A],
        nilify_unlisted_types_on_load: [:gone],
        on_replace: :delete

      embeds_one :holder, Holder, source: :channel2

      timestamps()
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @parent_params %{"date" => ~U[2020-05-28 02:57:19Z], "text" => "text"}

  defp cast(parent, params, fields) do
    changeset = Changeset.cast(parent, Map.merge(@parent_params, params), [:date, :text])
    Enum.reduce(fields, changeset, &PolymorphicEmbed.cast_polymorphic_embed(&2, &1))
  end

  # Runs the prepare functions as the repo does before it writes the parent.
  defp run_prepare(changeset) do
    changeset.prepare
    |> Enum.reverse()
    |> Enum.reduce(%{changeset | repo: Repo, action: :insert}, & &1.(&2))
  end

  test "inserts embeds of more than one type that are only in the data" do
    parent = %Parent{channel: %B{name: "b"}, contexts: [%A{name: "a"}, %B{name: "b"}]}

    inserted = parent |> cast(%{}, [:channel, :contexts]) |> Repo.insert!()

    assert %B{name: "b", id: id} = inserted.channel
    assert id
    assert [%A{name: "a"}, %B{name: "b"}] = inserted.contexts
    assert Enum.all?(inserted.contexts, & &1.id)
  end

  test "builds forms when the changes hold structs" do
    changeset =
      %Parent{}
      |> Changeset.change()
      |> Changeset.put_change(:contexts, [%A{name: "a"}])

    form = Phoenix.Component.to_form(changeset)
    assert [%{data: %A{name: "a"}}] = Helpers.to_form(changeset, form, :contexts, [])
  end

  test "builds forms after the repo prepared the changes" do
    changeset =
      %Parent{}
      |> cast(%{"contexts" => [%{"__type__" => "a", "name" => "a"}]}, [:contexts])
      |> run_prepare()

    form = Phoenix.Component.to_form(changeset)
    assert [%{data: %A{name: "a"}}] = Helpers.to_form(changeset, form, :contexts, [])
  end

  test "generates ids of polymorphic embeds inside an ordinary embed of a child" do
    params = %{
      "channel" => %{
        "__type__" => "wrapper",
        "inner" => %{"leaf" => %{"__type__" => "a", "name" => "leaf"}}
      }
    }

    inserted = %Parent{} |> cast(params, [:channel]) |> Repo.insert!()

    assert %Wrapper{inner: %Inner{id: inner_id, leaf: %A{name: "leaf", id: id}}} =
             inserted.channel

    assert id
    assert inner_id
  end

  test "replaces a list with entries that the load kept as maps" do
    parent = %Parent{contexts2: [%{"__type__" => "old", "name" => "old"}, %A{id: "1"}]}

    changeset =
      cast(parent, %{"contexts2" => [%{"__type__" => "a", "name" => "new"}]}, [:contexts2])

    assert changeset.valid?
    assert [%A{name: "new"}] = Changeset.apply_changes(changeset).contexts2

    changeset = cast(parent, %{"contexts2" => []}, [:contexts2])
    assert changeset.valid?
    assert [] = Changeset.apply_changes(changeset).contexts2
  end

  test "replaces a list with entries that the load set to nil" do
    parent = %Parent{contexts3: [nil, %A{id: "1"}]}

    changeset =
      cast(parent, %{"contexts3" => [%{"__type__" => "a", "name" => "new"}]}, [:contexts3])

    assert changeset.valid?
    assert [%A{name: "new"}] = Changeset.apply_changes(changeset).contexts3

    changeset = cast(parent, %{"contexts3" => []}, [:contexts3])
    assert changeset.valid?
    assert [] = Changeset.apply_changes(changeset).contexts3
  end

  test "generates the id of a polymorphic embed that is only in the data of an ordinary embed" do
    parent = %Parent{holder: %Holder{name: "old", leaf: %A{name: "leaf"}}}

    inserted =
      parent
      |> Changeset.cast(Map.merge(@parent_params, %{"holder" => %{"name" => "new"}}), [
        :date,
        :text
      ])
      |> Changeset.cast_embed(:holder)
      |> Repo.insert!()

    assert %Holder{name: "new", leaf: %A{name: "leaf", id: id}} = inserted.holder
    assert id
  end

  test "generates the id of a polymorphic embed that is only in the data of a polymorphic child" do
    parent = %Parent{channel: %Holder{id: "h1", name: "old", leaf: %A{name: "leaf"}}}
    params = %{"channel" => %{"__type__" => "holder", "name" => "new"}}

    inserted = parent |> cast(params, [:channel]) |> Repo.insert!()

    assert %Holder{name: "new", leaf: %A{name: "leaf", id: id}} = inserted.channel
    assert id
  end

  test "applies a struct that put_change/3 set before the cast" do
    changeset =
      %Parent{}
      |> Changeset.change()
      |> Changeset.put_change(:channel, %A{name: "a"})
      |> PolymorphicEmbed.cast_polymorphic_embed(:channel)

    assert %A{name: "a"} = Changeset.apply_changes(changeset).channel
    assert %A{name: "a"} = Changeset.get_field(changeset, :channel)

    changeset =
      %Parent{}
      |> Changeset.change()
      |> Changeset.put_change(:channel, %A{name: "a"})
      |> PolymorphicEmbed.cast_polymorphic_embed(:channel, required: true)

    assert changeset.valid?
  end

  describe "put_polymorphic_embed/3" do
    # After the cast, Ecto.Changeset.put_change/3 and update_change/3 accept
    # only one schema module for the field, as for an Ecto embed.
    test "edits a list of more than one type" do
      params = %{
        "contexts" => [%{"__type__" => "a", "name" => "a"}, %{"__type__" => "b", "name" => "b"}]
      }

      changeset = cast(%Parent{}, params, [:contexts])

      assert_raise ArgumentError, ~r/expected changeset data to be a/, fn ->
        Changeset.update_change(changeset, :contexts, & &1)
      end

      same =
        PolymorphicEmbed.put_polymorphic_embed(
          changeset,
          :contexts,
          Changeset.get_change(changeset, :contexts)
        )

      assert [%A{name: "a"}, %B{name: "b"}] = Changeset.apply_changes(same).contexts

      structs =
        PolymorphicEmbed.put_polymorphic_embed(changeset, :contexts, [
          %A{name: "x"},
          %B{name: "y"}
        ])

      assert [%A{name: "x"}, %B{name: "y"}] = Changeset.apply_changes(structs).contexts

      maps =
        PolymorphicEmbed.put_polymorphic_embed(changeset, :contexts, [
          %{__type__: "b", name: "m"},
          [__type__: "a", name: "n"]
        ])

      assert [%B{name: "m"}, %A{name: "n"}] = Changeset.apply_changes(maps).contexts

      inserted = Repo.insert!(maps)
      assert [%B{name: "m", id: b_id}, %A{name: "n", id: a_id}] = inserted.contexts
      assert b_id && a_id
    end

    test "updates, keeps and replaces rows of the data by module and primary key" do
      parent = %Parent{contexts: [%A{id: "a1", name: "a"}, %B{id: "b1", name: "b"}]}
      changeset = Changeset.change(parent)

      assert PolymorphicEmbed.put_polymorphic_embed(changeset, :contexts, parent.contexts).changes ==
               %{}

      changeset =
        PolymorphicEmbed.put_polymorphic_embed(changeset, :contexts, [
          %{id: "b1", name: "new b"},
          %A{name: "new a"}
        ])

      assert [
               %{action: :replace, data: %A{id: "a1"}},
               %{action: :update, data: %B{id: "b1"}, changes: %{name: "new b"}},
               %{action: :insert, data: %A{id: new_id}}
             ] = changeset.changes.contexts

      assert new_id

      assert [%B{id: "b1", name: "new b"}, %A{name: "new a"}] =
               Changeset.apply_changes(changeset).contexts
    end

    test "generates ids of ordinary embeds in the data of a child" do
      changeset =
        %Parent{}
        |> cast(%{}, [])
        |> PolymorphicEmbed.put_polymorphic_embed(:channel, %Wrapper{holder: %Holder{name: "h"}})

      inserted = Repo.insert!(changeset)

      assert %Wrapper{id: wrapper_id, holder: %Holder{name: "h", id: holder_id}} =
               inserted.channel

      assert wrapper_id
      assert holder_id
    end

    test "replaces data that holds only entries from the load options with an empty list" do
      parent = %Parent{contexts2: [%{"__type__" => "old", "name" => "old"}]}

      changeset = PolymorphicEmbed.put_polymorphic_embed(Changeset.change(parent), :contexts2, [])

      assert Map.has_key?(changeset.changes, :contexts2)
      assert [] = Changeset.apply_changes(changeset).contexts2
    end

    test "keeps the with: function of the cast for the forms" do
      parent = %Parent{channel: %A{id: "a1", name: nil}}

      changeset =
        parent
        |> Changeset.cast(@parent_params, [:date, :text])
        |> PolymorphicEmbed.cast_polymorphic_embed(:channel,
          with: [a: &A.required_changeset/2]
        )
        |> PolymorphicEmbed.put_polymorphic_embed(:channel, parent.channel)

      refute Map.has_key?(changeset.changes, :channel)

      form = Phoenix.Component.to_form(changeset, action: :validate)
      [child_form] = Helpers.to_form(form.source, form, :channel, [])
      assert child_form.errors == [name: {"can't be blank", [validation: :required]}]
    end

    test "keeps the id of a new child that the caller gives in the form" do
      id = Ecto.UUID.generate()

      changeset =
        %Parent{}
        |> cast(%{}, [])
        |> PolymorphicEmbed.put_polymorphic_embed(:channel, %A{id: id, name: "a"})

      form = Phoenix.Component.to_form(changeset)
      [child_form] = Helpers.to_form(changeset, form, :channel, [])

      assert child_form.data.id == id
      assert {:id, id} in child_form.hidden
    end

    test "prepares a put that a prepare function of the parent runs" do
      changeset =
        %Parent{}
        |> Changeset.cast(@parent_params, [:date, :text])
        |> Changeset.prepare_changes(
          &PolymorphicEmbed.put_polymorphic_embed(&1, :channel, %A{name: "a"})
        )

      inserted = Repo.insert!(changeset)
      assert %A{name: "a", id: id} = inserted.channel
      assert id
    end

    test "gives an error and keeps the data for nil as a list of embeds" do
      parent = %Parent{contexts: [%A{id: "a1", name: "a"}]}
      changeset = PolymorphicEmbed.put_polymorphic_embed(Changeset.change(parent), :contexts, nil)

      refute changeset.valid?
      refute Map.has_key?(changeset.changes, :contexts)
      assert changeset.errors == [contexts: {"is invalid", [type: {:array, :map}]}]
    end

    test "gives an error for a single embed that is not a map" do
      changeset =
        PolymorphicEmbed.put_polymorphic_embed(Changeset.change(%Parent{}), :channel, "a")

      refute changeset.valid?
      assert changeset.errors == [channel: {"is invalid", [type: :map]}]
    end

    test "changes the type of a single embed" do
      changeset =
        %Parent{}
        |> cast(%{"channel" => %{"__type__" => "a", "name" => "a"}}, [:channel])
        |> PolymorphicEmbed.put_polymorphic_embed(:channel, %B{name: "b"})

      assert %{action: :insert, data: %B{}} = changeset.changes.channel
      assert %B{name: "b"} = Changeset.apply_changes(changeset).channel

      changeset = PolymorphicEmbed.put_polymorphic_embed(changeset, :channel, nil)
      refute Map.has_key?(changeset.changes, :channel)
    end
  end

  test "generates the id of an ordinary embed in a polymorphic child that the insert updates" do
    parent = %Parent{channel: %Wrapper{id: "w1", holder: %Holder{name: "old"}}}
    params = %{"channel" => %{"__type__" => "wrapper", "holder" => %{"name" => "new"}}}

    inserted = parent |> cast(params, [:channel]) |> Repo.insert!()

    assert %Wrapper{id: "w1", holder: %Holder{name: "new", id: id}} = inserted.channel
    assert id
  end

  test "raises when a prepare function of a child adds an error" do
    changeset =
      %Parent{}
      |> Changeset.cast(
        Map.merge(@parent_params, %{"channel" => %{"__type__" => "a", "name" => "a"}}),
        [:date, :text]
      )
      |> PolymorphicEmbed.cast_polymorphic_embed(:channel,
        with: [a: &A.failing_prepare_changeset/2]
      )

    assert changeset.valid?

    assert_raise ArgumentError,
                 ~r/is invalid, but the parent changeset was not marked as invalid/,
                 fn ->
                   Repo.insert(changeset)
                 end
  end

  # merge/2 takes the types of the second changeset, so the cast changeset
  # must be the second argument.
  test "keeps structs after merge with the cast changeset as second argument" do
    changeset = cast(%Parent{}, %{"channel" => %{"__type__" => "a", "name" => "a"}}, [:channel])
    merged = Changeset.merge(Changeset.change(%Parent{}), changeset)

    assert %A{name: "a"} = Changeset.get_field(merged, :channel)
    assert %A{name: "a"} = Changeset.apply_changes(merged).channel
  end

  test "prepares a cast that a prepare function of the parent runs" do
    changeset =
      %Parent{}
      |> Changeset.cast(@parent_params, [:date, :text])
      |> Changeset.prepare_changes(fn changeset ->
        changeset
        |> Changeset.cast(%{"channel" => %{"__type__" => "a", "name" => "a"}}, [])
        |> PolymorphicEmbed.cast_polymorphic_embed(:channel)
      end)

    inserted = Repo.insert!(changeset)
    assert %A{name: "a", id: id} = inserted.channel
    assert id
    assert %A{name: "a", id: ^id} = Repo.get!(Parent, inserted.id).channel
  end

  test "inserts the struct that apply_changes returns" do
    params = %{"channel" => %{"__type__" => "a", "name" => "a"}}

    inserted =
      %Parent{}
      |> cast(params, [:channel])
      |> Changeset.apply_changes()
      |> Repo.insert!()

    assert %A{name: "a", id: id} = inserted.channel
    assert id
  end
end
