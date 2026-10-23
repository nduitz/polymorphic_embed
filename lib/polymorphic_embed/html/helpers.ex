if Code.ensure_loaded?(Phoenix.HTML) && Code.ensure_loaded?(Phoenix.HTML.Form) do
  defmodule PolymorphicEmbed.HTML.Helpers do
    @doc """
    Returns the polymorphic type of the given field in the given form data.
    """
    def get_polymorphic_type(%Phoenix.HTML.Form{} = form, field) do
      %schema{} = form.source.data

      case form[field] && form[field].value do
        %Ecto.Changeset{data: value} ->
          PolymorphicEmbed.get_polymorphic_type(schema, field, value)

        %_{} = value ->
          PolymorphicEmbed.get_polymorphic_type(schema, field, value)

        %{} = map ->
          case PolymorphicEmbed.get_polymorphic_module(schema, field, map) do
            nil ->
              nil

            module ->
              PolymorphicEmbed.get_polymorphic_type(schema, field, module)
          end

        list when is_list(list) ->
          raise "Cannot infer the polymorphic type as the list of embeds may contain multiple types"

        nil ->
          nil
      end
    end

    def get_polymorphic_type(%Phoenix.HTML.FormField{} = form_field) do
      %{field: field_name, form: parent_form} = form_field
      get_polymorphic_type(parent_form, field_name)
    end

    @doc """
    Returns the source data structure
    """
    def source_data(%Phoenix.HTML.Form{} = form) do
      form.source.data
    end

    @doc """
    Returns the source data structure
    """
    def source_module(%Phoenix.HTML.Form{} = form) do
      form.source.data.__struct__
    end

    # Builds the child forms as phoenix_ecto does for embeds_one and embeds_many.
    # As in phoenix_ecto, the parent action comes from the form, because
    # to_form(changeset, action: :validate) sets it on the form.
    def to_form(source_changeset, %{action: parent_action} = form, field, options) do
      id = to_string(form.id <> "_#{field}")
      name = to_string(form.name <> "[#{field}]")

      %schema{} = source_changeset.data
      field_opts = PolymorphicEmbed.get_field_opts(schema, field)
      type_field_name = Map.fetch!(field_opts, :type_field_name)
      # correctly set id and name for embeds_many inputs
      array? = Map.get(field_opts, :array?, false)

      source_changeset
      |> child_changesets(form, field, options)
      |> Enum.with_index()
      |> Enum.map(fn {changeset, i} ->
        changeset = changeset |> hide_generated_id() |> apply_action(parent_action)
        errors = get_errors(changeset, parent_action)
        index_string = Integer.to_string(i)
        type = PolymorphicEmbed.get_polymorphic_type(schema, field, changeset.data)

        %Phoenix.HTML.Form{
          source: changeset,
          impl: Phoenix.HTML.FormData.Ecto.Changeset,
          id: if(array?, do: id <> "_" <> index_string, else: id),
          name: if(array?, do: name <> "[" <> index_string <> "]", else: name),
          index: if(array?, do: i),
          errors: errors,
          data: changeset.data,
          action: parent_action,
          params: changeset.params || %{},
          hidden: primary_key_hidden(changeset.data) ++ [{type_field_name, to_string(type)}],
          options: options
        }
      end)
    end

    # The cast keeps the child changesets in the changes. Rows that the cast
    # replaces get no form. Without a change, the forms use the data. The
    # changes can also hold structs, for example after the repo prepared them
    # or after put_change/3, so they become changesets as the data does.
    defp child_changesets(source_changeset, form, field, options) do
      case Map.fetch(source_changeset.changes, field) do
        {:ok, value} ->
          on_cast = on_cast(source_changeset, field)

          value
          |> List.wrap()
          |> Enum.reject(&match?(%Ecto.Changeset{action: :replace}, &1))
          |> Enum.map(&to_changeset(&1, on_cast))

        :error ->
          struct = Ecto.Changeset.apply_changes(source_changeset)
          on_cast = on_cast(source_changeset, field)

          struct
          |> list_data_from_struct(form, field, options)
          |> Enum.map(&to_changeset(&1, on_cast))
      end
    end

    defp list_data_from_struct(struct, form, field, options) do
      case Map.get(struct, field) do
        nil ->
          type = Keyword.get(options, :polymorphic_type, get_polymorphic_type(form, field))
          module = PolymorphicEmbed.get_polymorphic_module(struct.__struct__, field, type)
          if module, do: [struct(module)], else: []

        data ->
          List.wrap(data)
      end
    end

    # The cast stores its changeset function in the embed type of a changed
    # field, or in the options of the PolymorphicEmbed type.
    defp on_cast(changeset, field) do
      case Map.get(changeset.types, field) do
        {:embed, %{on_cast: on_cast}} when is_function(on_cast, 2) -> on_cast
        {:parameterized, {PolymorphicEmbed, %{on_cast: on_cast}}} -> on_cast
        {:array, {:parameterized, {PolymorphicEmbed, %{on_cast: on_cast}}}} -> on_cast
        _ -> nil
      end
    end

    defp to_changeset(%Ecto.Changeset{} = changeset, _on_cast), do: changeset
    defp to_changeset(data, nil), do: Ecto.Changeset.change(data)
    defp to_changeset(data, on_cast), do: on_cast.(data, %{})

    # The cast generates the id of a new child into its data, so that
    # apply_changes/1 and the repo give the same id. A new Ecto embed has no id
    # before the insert, so the form of a new child does not show that id.
    # Only a cast child has a params map. A struct that the caller gives to
    # put_polymorphic_embed/3 keeps its id in the form.
    defp hide_generated_id(
           %Ecto.Changeset{action: :insert, params: %{}, data: %module{} = data} = changeset
         ) do
      case module.__schema__(:autogenerate_id) do
        {key, _source, :binary_id} -> %{changeset | data: Map.put(data, key, nil)}
        _ -> changeset
      end
    end

    defp hide_generated_id(changeset), do: changeset

    # As in phoenix_ecto, the hidden inputs hold the primary key of the data.
    defp primary_key_hidden(%module{} = data) do
      for key <- module.__schema__(:primary_key), value = Map.fetch!(data, key), do: {key, value}
    end

    # If the parent changeset had no action, we need to remove the action
    # from children changeset so we ignore all errors accordingly.
    defp apply_action(changeset, nil), do: %{changeset | action: nil}
    defp apply_action(changeset, _action), do: changeset

    defp get_errors(_changeset, nil), do: []
    defp get_errors(_changeset, :ignore), do: []
    defp get_errors(%{errors: errors}, _action), do: errors
  end
end
