defmodule PolymorphicEmbed.Embedded do
  @moduledoc false

  # A copy of the logic of Ecto.Embedded.prepare/4 from Ecto 3.12. That
  # function is not public API, so polymorphic_embed keeps its own copy.
  #
  # The repo calls Ecto.Embedded.prepare/4 only for the embeds of the schema
  # that it writes. A polymorphic child is not such an embed, so
  # polymorphic_embed calls this copy for the ordinary embeds of each child.
  # It replaces their changesets with structs, runs their prepare functions
  # and generates their ids and timestamps, as Ecto does.

  alias Ecto.Changeset

  def prepare(changeset, embeds, adapter, repo_action) do
    %{changes: changes, types: types, repo: repo} = changeset

    changes
    |> Map.take(embeds)
    |> Map.new(fn {name, changeset_or_changesets} ->
      {:embed, embed} = Map.fetch!(types, name)
      {name, prepare_each(embed, changeset_or_changesets, adapter, repo, repo_action)}
    end)
  end

  defp prepare_each(%{cardinality: :one}, nil, _adapter, _repo, _repo_action), do: nil

  defp prepare_each(%{cardinality: :one} = embed, changeset, adapter, repo, repo_action) do
    action = normalize_action(changeset.action, repo_action, embed)
    changeset = run_prepare(changeset, repo)
    to_struct(changeset, action, embed, adapter)
  end

  defp prepare_each(%{cardinality: :many} = embed, changesets, adapter, repo, repo_action) do
    for changeset <- changesets,
        action = normalize_action(changeset.action, repo_action, embed),
        changeset = run_prepare(changeset, repo),
        prepared = to_struct(changeset, action, embed, adapter),
        do: prepared
  end

  defp to_struct(%Changeset{valid?: false}, _action, %{related: schema}, _adapter) do
    raise ArgumentError,
          "changeset for embedded #{inspect(schema)} is invalid, " <>
            "but the parent changeset was not marked as invalid"
  end

  defp to_struct(%Changeset{data: %{__struct__: actual}}, _action, %{related: expected}, _adapter)
       when actual != expected do
    raise ArgumentError,
          "expected changeset for embedded schema `#{inspect(expected)}`, " <>
            "got: #{inspect(actual)}"
  end

  defp to_struct(%Changeset{changes: changes, data: schema}, :update, _embed, _adapter)
       when changes == %{} do
    schema
  end

  defp to_struct(%Changeset{}, :delete, _embed, _adapter), do: nil

  defp to_struct(%Changeset{data: data} = changeset, action, %{related: schema}, adapter) do
    %{data: struct, changes: changes} =
      changeset =
      maybe_surface_changes(changeset, data, schema, action)

    embeds = prepare(changeset, schema.__schema__(:embeds), adapter, action)

    changes
    |> Map.merge(embeds)
    |> autogenerate_id(struct, action, schema, adapter)
    |> autogenerate(action, schema)
    |> then(&struct(struct, &1))
  end

  # On insert, Ecto puts the fields of the data that are not nil into the
  # changes, and it turns embeds of the data into changesets with the action
  # :insert. This copy does the same without the internal Ecto relation code.
  def maybe_surface_changes(changeset, data, schema, :insert) do
    embeds = schema.__schema__(:embeds)

    changes =
      Enum.reduce(schema.__schema__(:fields), changeset.changes, fn field, changes ->
        case {changes, Map.get(data, field)} do
          {%{^field => _}, _} -> changes
          {_, nil} -> changes
          {_, value} -> Map.put(changes, field, surface_value(field in embeds, value))
        end
      end)

    %{changeset | changes: changes}
  end

  def maybe_surface_changes(changeset, _data, _schema, _action), do: changeset

  defp surface_value(false, value), do: value
  defp surface_value(true, list) when is_list(list), do: Enum.map(list, &surface_value(true, &1))
  defp surface_value(true, struct), do: %{Changeset.change(struct) | action: :insert}

  defp run_prepare(changeset, repo) do
    changeset = %{changeset | repo: repo}

    Enum.reduce(Enum.reverse(changeset.prepare), changeset, fn fun, acc ->
      case fun.(acc) do
        %Changeset{} = acc ->
          acc

        other ->
          raise "expected function #{inspect(fun)} given to Ecto.Changeset.prepare_changes/2 " <>
                  "to return an Ecto.Changeset, got: `#{inspect(other)}`"
      end
    end)
  end

  defp autogenerate_id(changes, _struct, :insert, schema, adapter) do
    case schema.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        Map.put_new_lazy(changes, key, fn -> adapter.autogenerate(:embed_id) end)

      {_key, _source, :id} ->
        raise ArgumentError,
              "embedded schema `#{inspect(schema)}` cannot autogenerate `:id` primary keys, " <>
                "those are typically used for auto-incrementing constraints. " <>
                "Maybe you meant to use `:binary_id` instead?"

      nil ->
        changes
    end
  end

  defp autogenerate_id(changes, struct, :update, _schema, _adapter) do
    for {_, nil} <- Ecto.primary_key(struct) do
      raise Ecto.NoPrimaryKeyValueError, struct: struct
    end

    changes
  end

  defp autogenerate(changes, action, schema) do
    autogen_fields = action |> action_to_auto() |> schema.__schema__()

    Enum.reduce(autogen_fields, changes, fn {fields, {mod, fun, args}}, acc ->
      case Enum.reject(fields, &Map.has_key?(changes, &1)) do
        [] ->
          acc

        fields ->
          generated = apply(mod, fun, args)
          Enum.reduce(fields, acc, &Map.put(&2, &1, generated))
      end
    end)
  end

  defp action_to_auto(:insert), do: :autogenerate
  defp action_to_auto(:update), do: :autoupdate

  defp normalize_action(:replace, _, %{on_replace: :delete}), do: :delete
  defp normalize_action(:update, :insert, _), do: :insert
  defp normalize_action(action, _, _), do: action
end
