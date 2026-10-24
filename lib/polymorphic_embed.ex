defmodule PolymorphicEmbed do
  use Ecto.ParameterizedType

  @type t() :: any()

  require PolymorphicEmbed.OptionsValidator

  alias Ecto.Changeset
  alias PolymorphicEmbed.OptionsValidator

  defmacro polymorphic_embeds_one(field_name, opts) do
    opts =
      opts
      |> Keyword.put_new(:array?, false)
      |> Keyword.put_new(:default, nil)
      |> Keyword.update!(:types, &expand_alias(&1, __CALLER__))

    quote do
      field(unquote(field_name), PolymorphicEmbed, unquote(opts))
    end
  end

  defmacro polymorphic_embeds_many(field_name, opts) do
    opts =
      opts
      |> Keyword.put_new(:array?, true)
      |> Keyword.put_new(:default, [])
      |> Keyword.update!(:types, &expand_alias(&1, __CALLER__))

    quote do
      field(unquote(field_name), {:array, PolymorphicEmbed}, unquote(opts))
    end
  end

  # Expand module aliases to avoid creating compile-time dependencies between the
  # parent schema that uses `polymorphic_embeds_one` or `polymorphic_embeds_many`
  # and the embedded schemas.
  defp expand_alias(types, env) when is_list(types) do
    Enum.map(types, fn
      {type_name, type_opts} when is_list(type_opts) ->
        {type_name, Keyword.update!(type_opts, :module, &do_expand_alias(&1, env))}

      {type_name, module} ->
        {type_name, do_expand_alias(module, env)}
    end)
  end

  # If it's not a list or a map, it means it's being defined by a reference of some kind,
  # possibly via module attribute like:
  # @types [twilio: PolymorphicEmbed.Channel.TwilioSMSProvider]
  # # ...
  #   polymorphic_embeds_one(:fallback_provider, types: @types)
  # which means we can't expand aliases
  defp expand_alias(types, _env) do
    types
  end

  defp do_expand_alias({:__aliases__, _, _} = ast, env) do
    Macro.expand(ast, %{env | function: {:__schema__, 2}})
  end

  defp do_expand_alias(ast, _env) do
    ast
  end

  @impl true
  def type(_params), do: :map

  @impl true
  def init(opts) do
    opts = Keyword.put_new(opts, :on_replace, nil)
    # opts = Keyword.put_new(opts, :type_field_name, :__type__)
    # TODO remove in v6
    opts = Keyword.put_new(opts, :type_field_name, Keyword.get(opts, :type_field, :__type__))
    opts = Keyword.put_new(opts, :on_type_not_found, :changeset_error)
    opts = Keyword.put_new(opts, :nilify_unlisted_types_on_load, [])
    opts = Keyword.put_new(opts, :retain_unlisted_types_on_load, [])

    OptionsValidator.validate!(opts)

    if Keyword.get(opts, :on_replace) not in [:update, :delete] do
      raise ArgumentError,
            "`:on_replace` option for polymorphic embed must be set to `:update` (single embed) or `:delete` (list of embeds)"
    end

    types_metadata =
      opts
      |> Keyword.fetch!(:types)
      |> Enum.map(fn
        {type_name, type_opts} when is_list(type_opts) ->
          {type_name, type_opts}

        {type_name, module} ->
          {type_name, module: module}
      end)
      |> Enum.map(fn
        {type_name, type_opts} ->
          %{
            type: type_name,
            module: Keyword.fetch!(type_opts, :module),
            identify_by_fields:
              Keyword.get(type_opts, :identify_by_fields, []) |> Enum.map(&to_string/1)
          }
      end)

    %{
      array?: Keyword.fetch!(opts, :array?),
      default: Keyword.fetch!(opts, :default),
      use_parent_field_for_type: Keyword.get(opts, :use_parent_field_for_type),
      on_replace: Keyword.fetch!(opts, :on_replace),
      on_type_not_found: Keyword.fetch!(opts, :on_type_not_found),
      nilify_unlisted_types_on_load: Keyword.fetch!(opts, :nilify_unlisted_types_on_load),
      retain_unlisted_types_on_load: Keyword.fetch!(opts, :retain_unlisted_types_on_load),
      type_field_name: Keyword.fetch!(opts, :type_field_name),
      types_metadata: types_metadata
    }
  end

  def cast_polymorphic_embed(changeset, field, cast_opts \\ [])

  # credo:disable-for-next-line
  def cast_polymorphic_embed(%Ecto.Changeset{} = changeset, field, cast_opts) do
    field_opts = get_field_opts(changeset.data.__struct__, field)

    raise_if_invalid_options(field, field_opts)

    %{types_metadata: types_metadata} = field_opts

    required = Keyword.get(cast_opts, :required, false)
    with = Keyword.get(cast_opts, :with, nil)

    changeset_fun = &changeset_fun(&1, &2, with, types_metadata)

    # used for sort_param and drop_param support for many embeds
    sort = param_value_for_cast_opt(:sort_param, cast_opts, changeset.params)
    drop = param_value_for_cast_opt(:drop_param, cast_opts, changeset.params)

    changeset =
      if required, do: update_in(changeset.required, &[field | &1]), else: changeset

    changeset
    |> do_cast_polymorphic_embed(field, cast_opts, field_opts, changeset_fun, sort, drop)
    |> put_embed_type(field, field_opts, &changeset_fun.(&1, &2))
    |> maybe_add_required_error(field, required)
    |> register_prepare(field)
  end

  def cast_polymorphic_embed(_, _, _) do
    raise "cast_polymorphic_embed/3 only accepts a changeset as first argument"
  end

  defp do_cast_polymorphic_embed(
         changeset,
         field,
         cast_opts,
         field_opts,
         changeset_fun,
         sort,
         drop
       ) do
    %{array?: array?} = field_opts

    case Map.fetch(changeset.params || %{}, to_string(field)) do
      # consider sort and drop params even if the assoc param was not given, as in Ecto
      :error when (array? and is_list(sort)) or is_list(drop) ->
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), field_opts) end
        params_for_field = apply_sort_drop(%{}, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts
        )

      :error ->
        changeset

      {:ok, params_for_field}
      when array? and not is_list(params_for_field) and not is_map(params_for_field) ->
        add_invalid_error(changeset, field, array?)

      {:ok, nil} when array? ->
        add_invalid_error(changeset, field, array?)

      {:ok, params_for_field}
      when not array? and not is_map(params_for_field) and not is_nil(params_for_field) ->
        add_invalid_error(changeset, field, array?)

      {:ok, nil} ->
        put_nil(changeset, field)

      {:ok, map} when map == %{} and not array? ->
        changeset

      {:ok, params_for_field} when array? ->
        create_sort_default = fn -> sort_create(Enum.into(cast_opts, %{}), field_opts) end
        params_for_field = apply_sort_drop(params_for_field, sort, drop, create_sort_default)

        cast_polymorphic_embeds_many(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts
        )

      {:ok, params_for_field} when is_map(params_for_field) and not array? ->
        cast_polymorphic_embeds_one(
          changeset,
          field,
          changeset_fun,
          params_for_field,
          field_opts
        )
    end
  end

  # As in Ecto, a required embed must not be nil or an empty list after the cast.
  defp maybe_add_required_error(changeset, _field, false), do: changeset

  defp maybe_add_required_error(changeset, field, true) do
    if Keyword.has_key?(changeset.errors, field) or
         Ecto.Changeset.get_field(changeset, field) not in [nil, []] do
      changeset
    else
      Ecto.Changeset.add_error(changeset, field, "can't be blank", validation: :required)
    end
  end

  defp sort_create(%{sort_param: _} = cast_opts, field_opts) do
    default_type = Map.get(cast_opts, :default_type_on_sort_create)
    type_field_name = Map.fetch!(field_opts, :type_field_name)
    types_metadata = Map.fetch!(field_opts, :types_metadata)

    case default_type do
      nil ->
        # If type is not provided, use the first type from types_metadata
        [first_type_metadata | _] = types_metadata
        first_type = first_type_metadata.type
        %{type_field_name => first_type}

      _ ->
        default_type =
          case default_type do
            fun when is_function(fun, 0) -> fun.()
            _ -> default_type
          end

        # If type is provided, ensure it exists in types_metadata
        unless Enum.find(types_metadata, &(&1.type === default_type)) do
          raise "incorrect type atom #{inspect(default_type)}"
        end

        %{type_field_name => default_type}
    end
  end

  defp sort_create(_cast_opts, _field_opts), do: nil

  defp apply_sort_drop(value, sort, drop, create_sort_default) when is_map(value) do
    drop = if is_list(drop), do: drop, else: []

    {sorted, pending} =
      if is_list(sort) do
        Enum.map_reduce(sort -- drop, value, &Map.pop(&2, &1, create_sort_default.()))
      else
        {[], value}
      end

    sorted ++
      (pending
       |> Map.drop(drop)
       |> Enum.map(&key_as_int/1)
       |> Enum.sort()
       |> Enum.map(&elem(&1, 1)))
  end

  defp apply_sort_drop(value, _sort, _drop, _default) do
    value
  end

  defp param_value_for_cast_opt(opt, opts, params) do
    if key = opts[opt] do
      Map.get(params, Atom.to_string(key), nil)
    end
  end

  defp key_as_int({key, val}) when is_binary(key) do
    case Integer.parse(key) do
      {key, ""} -> {key, val}
      _ -> {key, val}
    end
  end

  # from Ecto
  # We check for the byte size to avoid creating unnecessary large integers
  # which would never map to a database key (u64 is 20 digits only).
  defp key_as_int({key, val}) when is_binary(key) and byte_size(key) < 32 do
    case Integer.parse(key) do
      {key, ""} -> {key, val}
      _ -> {key, val}
    end
  end

  defp key_as_int(key_val), do: key_val

  defp changeset_fun(struct, params, with, types_metadata) when is_list(with) do
    type = do_get_polymorphic_type(struct, types_metadata)

    case Keyword.get(with, type) do
      {module, function_name, args} ->
        apply(module, function_name, [struct, params | args])

      nil ->
        struct.__struct__.changeset(struct, params)

      fun ->
        apply(fun, [struct, params])
    end
  end

  defp changeset_fun(struct, params, nil, _) do
    struct.__struct__.changeset(struct, params)
  end

  defp cast_polymorphic_embeds_one(changeset, field, changeset_fun, params, field_opts) do
    %{on_type_not_found: on_type_not_found} = field_opts

    data_for_field = Map.fetch!(changeset.data, field)

    # We support partial update of the embed. If the type cannot be inferred from the parameters, or if the found type
    # hasn't changed, pass the data to the changeset.

    case action_and_struct(changeset, params, field_opts, data_for_field) do
      :type_not_found when on_type_not_found == :raise ->
        raise_cannot_infer_type_from_data(params)

      :type_not_found when on_type_not_found == :changeset_error ->
        Ecto.Changeset.add_error(changeset, field, "is invalid")

      :type_not_found when on_type_not_found == :nilify ->
        put_nil(changeset, field)

      {action, struct} ->
        struct = if action == :insert, do: autogenerate_id(struct, :insert), else: struct
        embed_changeset = %{changeset_fun.(struct, params) | action: action}

        if skip?(embed_changeset) do
          delete_embed_change(changeset, field)
        else
          put_embed_change(changeset, field, embed_changeset)
        end
    end
  end

  defp action_and_struct(changeset, params, field_opts, data_for_field) do
    %{
      types_metadata: types_metadata,
      type_field_name: type_field_name,
      use_parent_field_for_type: parent_field_for_type
    } = field_opts

    if parent_field_for_type != nil do
      type_from_map = Attrs.get(params, type_field_name)
      type_from_parent_field = Ecto.Changeset.fetch_field!(changeset, parent_field_for_type)

      cond do
        is_nil(type_from_parent_field) ->
          :type_not_found

        is_nil(type_from_map) ->
          module = get_polymorphic_module_for_type(type_from_parent_field, types_metadata)

          if is_nil(data_for_field) or data_for_field.__struct__ != module do
            {:insert, struct(module)}
          else
            {:update, data_for_field}
          end

        to_string(type_from_parent_field) != to_string(type_from_map) ->
          raise "type specified in the parent field \"#{type_from_parent_field}\" does not match the type in the embedded map \"#{type_from_map}\""

        true ->
          # type_from_parent_field and type_from_map match
          module = get_polymorphic_module_for_type(type_from_parent_field, types_metadata)

          if is_nil(data_for_field) or data_for_field.__struct__ != module do
            {:insert, struct(module)}
          else
            {:update, data_for_field}
          end
      end
    else
      case get_polymorphic_module_from_map(params, type_field_name, types_metadata) do
        nil ->
          if data_for_field do
            {:update, data_for_field}
          else
            :type_not_found
          end

        module when is_nil(data_for_field) ->
          {:insert, struct(module)}

        module ->
          if data_for_field.__struct__ != module do
            {:insert, struct(module)}
          else
            {:update, data_for_field}
          end
      end
    end
  end

  defp cast_polymorphic_embeds_many(changeset, field, _changeset_fun, list_params, _field_opts)
       when not is_list(list_params) do
    add_invalid_error(changeset, field, true)
  end

  defp cast_polymorphic_embeds_many(changeset, field, changeset_fun, list_params, field_opts) do
    if Enum.all?(list_params, &is_map/1) do
      do_cast_polymorphic_embeds_many(changeset, field, changeset_fun, list_params, field_opts)
    else
      add_invalid_error(changeset, field, true)
    end
  end

  # As in Ecto, the params match a row when each primary key, cast to its
  # type, is equal to the primary key of the row.
  defp same_pk?(%module{} = datum, params) do
    pks = module.__schema__(:primary_key)

    pks != [] and
      Enum.all?(pks, fn pk ->
        value = Map.get(datum, pk)

        case Ecto.Type.cast(module.__schema__(:type, pk), Attrs.get(params, pk)) do
          {:ok, param_value} -> not is_nil(value) and param_value == value
          _ -> false
        end
      end)
  end

  # The same error as Ecto gives for params that are not a map (or a list of maps).
  defp add_invalid_error(changeset, field, array?) do
    type = if array?, do: {:array, :map}, else: :map
    Ecto.Changeset.add_error(changeset, field, "is invalid", validation: :embed, type: type)
  end

  defp do_cast_polymorphic_embeds_many(changeset, field, changeset_fun, list_params, field_opts) do
    %{
      types_metadata: types_metadata,
      on_type_not_found: on_type_not_found,
      type_field_name: type_field_name
    } = field_opts

    list_data_for_field = Map.fetch!(changeset.data, field) || []

    # With nilify_unlisted_types_on_load or retain_unlisted_types_on_load, the
    # loaded list can hold nil or plain maps. They match no params, and the
    # cast drops them without a :replace changeset.
    structs = Enum.filter(list_data_for_field, &is_struct/1)

    # Each matched row is removed from the remaining data, as in Ecto.
    {embeds, remaining} =
      Enum.map_reduce(list_params, structs, fn params, remaining ->
        case get_polymorphic_module_from_map(params, type_field_name, types_metadata) do
          nil when on_type_not_found == :raise ->
            raise_cannot_infer_type_from_data(params)

          nil when on_type_not_found == :changeset_error ->
            {:error, remaining}

          nil when on_type_not_found == :ignore ->
            {:ignore, remaining}

          module ->
            index =
              Enum.find_index(remaining, &(&1.__struct__ == module and same_pk?(&1, params)))

            if index do
              {data_for_field, remaining} = List.pop_at(remaining, index)
              {%{changeset_fun.(data_for_field, params) | action: :update}, remaining}
            else
              new_struct = module |> struct() |> autogenerate_id(:insert)
              {%{changeset_fun.(new_struct, params) | action: :insert}, remaining}
            end
        end
      end)

    if Enum.any?(embeds, &(&1 == :error)) do
      Ecto.Changeset.add_error(changeset, field, "is invalid")
    else
      embeds = Enum.reject(embeds, &(&1 == :ignore))

      # As in Ecto, rows of the data that the params do not keep are replaced.
      replaced =
        remaining
        |> Enum.map(&%{Ecto.Changeset.change(&1) | action: :replace})
        |> Enum.reverse()

      if replaced == [] and Enum.all?(embeds, &skip?/1) and
           Enum.map(embeds, & &1.data) == list_data_for_field do
        delete_embed_change(changeset, field)
      else
        put_embed_change(changeset, field, replaced ++ embeds)
      end
    end
  end

  # As in Ecto, an update without changes is not a change.
  defp skip?(%Changeset{valid?: true, action: :update, changes: changes}), do: changes == %{}
  defp skip?(_changeset), do: false

  defp put_embed_change(changeset, field, value) do
    valid? =
      changeset.valid? and
        value |> List.wrap() |> Enum.all?(fn embed_changeset -> embed_changeset.valid? end)

    %{changeset | changes: Map.put(changeset.changes, field, value), valid?: valid?}
  end

  defp delete_embed_change(changeset, field) do
    %{changeset | changes: Map.delete(changeset.changes, field)}
  end

  defp put_nil(changeset, field) do
    if Map.fetch!(changeset.data, field) == nil do
      delete_embed_change(changeset, field)
    else
      %{changeset | changes: Map.put(changeset.changes, field, nil)}
    end
  end

  # The field keeps the PolymorphicEmbed type in the schema. When the field has
  # a change, it gets an embed type in the changeset, so that apply_changes/1,
  # get_field/2 and traverse_errors/2 handle the child changesets as for an Ecto
  # embed. Without a change, the field keeps its type, because on insert Ecto
  # builds changesets for the data of an embed type with one module only. The
  # type then keeps the on_cast function for the forms.
  defp put_embed_type(changeset, field, field_opts, on_cast) do
    if changesets_in_changes?(changeset, field) do
      put_embed_relation(changeset, field, field_opts, on_cast)
    else
      type = changeset.data.__struct__.__schema__(:type, field)
      %{changeset | types: Map.put(changeset.types, field, put_on_cast(type, on_cast))}
    end
  end

  # A struct that put_change/3 set before the cast stays a struct, so the field
  # keeps its type, as before. Ecto applies the embed type only to changesets.
  defp changesets_in_changes?(changeset, field) do
    case Map.fetch(changeset.changes, field) do
      {:ok, value} -> value |> List.wrap() |> Enum.all?(&match?(%Changeset{}, &1))
      :error -> false
    end
  end

  defp put_on_cast({:array, type}, on_cast), do: {:array, put_on_cast(type, on_cast)}

  defp put_on_cast({:parameterized, {PolymorphicEmbed, opts}}, on_cast),
    do: {:parameterized, {PolymorphicEmbed, Map.put(opts, :on_cast, on_cast)}}

  defp put_embed_relation(changeset, field, field_opts, on_cast) do
    %{array?: array?, on_replace: on_replace, types_metadata: [first_type | _]} = field_opts

    related =
      case List.wrap(Map.get(changeset.changes, field)) do
        [%Changeset{data: %module{}} | _] -> module
        _ -> first_type.module
      end

    embed = %Ecto.Embedded{
      cardinality: if(array?, do: :many, else: :one),
      field: field,
      owner: changeset.data.__struct__,
      related: related,
      on_cast: on_cast,
      on_replace: on_replace
    }

    %{changeset | types: Map.put(changeset.types, field, {:embed, embed})}
  end

  # Ecto reads the prepare functions of a changeset before it runs them. A
  # cast or a put inside a prepare function of the parent therefore prepares
  # the embeds at once. Ecto sets the repo on the changeset before it runs
  # the prepare functions. A changeset that the repo returns as an error is
  # invalid, so it keeps its child changesets.
  defp register_prepare(%Changeset{repo: repo, valid?: true} = changeset, field)
       when not is_nil(repo),
       do: prepare_embeds(changeset, field)

  defp register_prepare(changeset, field),
    do: Ecto.Changeset.prepare_changes(changeset, &prepare_embeds(&1, field))

  # Runs before the repo inserts or updates the parent. As Ecto does for
  # embeds, it turns the child changesets into structs and generates the ids.
  defp prepare_embeds(changeset, field) do
    case Map.fetch(changeset.changes, field) do
      {:ok, value} ->
        value = apply_embed(value, changeset.repo, changeset.action)
        # The value is a struct now, so the field gets its schema type back.
        type = changeset.data.__struct__.__schema__(:type, field)

        %{
          changeset
          | changes: Map.put(changeset.changes, field, value),
            types: Map.put(changeset.types, field, type)
        }

      # Ecto runs the prepare functions of an ordinary embed before it puts its
      # data into the changes. So data without a change can still need ids.
      :error ->
        data = Map.fetch!(changeset.data, field)

        case autogenerate_id(data, :insert) do
          ^data -> changeset
          data -> put_in(changeset.changes[field], data)
        end
    end
  end

  defp apply_embed(list, repo, repo_action) when is_list(list) do
    list |> Enum.map(&apply_embed(&1, repo, repo_action)) |> Enum.reject(&is_nil/1)
  end

  defp apply_embed(%Changeset{action: action}, _repo, _repo_action)
       when action in [:replace, :delete],
       do: nil

  defp apply_embed(%Changeset{data: %module{}} = embed_changeset, repo, repo_action) do
    # As in Ecto, a child update of a parent insert is an insert, so that the
    # ordinary embeds of the child also get their ids.
    action = if repo_action == :insert, do: :insert, else: embed_changeset.action

    embed_changeset =
      embed_changeset.prepare
      |> Enum.reverse()
      |> Enum.reduce(%{embed_changeset | repo: repo}, fn prepare, acc -> prepare.(acc) end)

    # As in Ecto, a prepare function cannot make a child invalid.
    unless embed_changeset.valid? do
      raise ArgumentError,
            "changeset for embedded #{inspect(module)} is invalid, " <>
              "but the parent changeset was not marked as invalid"
    end

    # As in Ecto, on insert the data of the child goes into its changes, so
    # that embeds in the data are prepared too.
    embed_changeset =
      PolymorphicEmbed.Embedded.maybe_surface_changes(
        embed_changeset,
        embed_changeset.data,
        module,
        action
      )

    # The ordinary Ecto embeds of the child get the same preparation as the
    # embeds of the parent: their prepare functions run and their ids are
    # generated. This also prepares polymorphic fields inside them.
    embeds =
      PolymorphicEmbed.Embedded.prepare(
        embed_changeset,
        module.__schema__(:embeds),
        repo.__adapter__(),
        action
      )

    changes =
      embed_changeset.changes
      |> Map.merge(embeds)
      |> prepare_polymorphic_changes(module, repo, action)

    embed_changeset.data
    |> struct(changes)
    |> autogenerate_id(action)
  end

  # On insert, a struct gets the same preparation as a new child changeset,
  # so that the embeds in its data get ids too.
  defp apply_embed(%_{} = struct, repo, :insert),
    do: apply_embed(%{Ecto.Changeset.change(struct) | action: :insert}, repo, :insert)

  defp apply_embed(%_{} = struct, _repo, _repo_action), do: autogenerate_id(struct, :insert)

  defp apply_embed(value, _repo, _repo_action), do: value

  # The polymorphic fields of a child can hold structs or changesets that no
  # cast prepared, for example from put_polymorphic_embed/3.
  defp prepare_polymorphic_changes(changes, module, repo, action) do
    Map.new(changes, fn {field, value} ->
      case module.__schema__(:type, field) do
        {:parameterized, {PolymorphicEmbed, _}} ->
          {field, apply_embed(value, repo, action)}

        {:array, {:parameterized, {PolymorphicEmbed, _}}} ->
          {field, apply_embed(value, repo, action)}

        _ ->
          {field, value}
      end
    end)
  end

  @impl true
  def cast(_data, _params),
    do:
      raise(
        "#{__MODULE__} must not be casted using Ecto.Changeset.cast/4, use #{__MODULE__}.cast_polymorphic_embed/2 instead."
      )

  @impl true
  def embed_as(_format, _params), do: :dump

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(data, loader, params) when is_map(data), do: do_load(data, loader, params)

  def load(data, loader, params) when is_binary(data),
    do: do_load(Jason.decode!(data), loader, params)

  def do_load(data, _loader, field_opts) do
    %{
      types_metadata: types_metadata,
      type_field_name: type_field_name
    } = field_opts

    case get_polymorphic_module_from_map(data, type_field_name, types_metadata) do
      nil ->
        retain_type_list =
          Map.fetch!(field_opts, :retain_unlisted_types_on_load) |> Enum.map(&to_string(&1))

        nilify_type_list =
          Map.fetch!(field_opts, :nilify_unlisted_types_on_load) |> Enum.map(&to_string(&1))

        type = Map.get(data, type_field_name |> to_string)

        cond do
          type in retain_type_list ->
            {:ok, data}

          type in nilify_type_list ->
            {:ok, nil}

          true ->
            raise_cannot_infer_type_from_data(data)
        end

      module when is_atom(module) ->
        {:ok, Ecto.embedded_load(module, data, :json)}
    end
  end

  @impl true
  def dump(%Ecto.Changeset{valid?: false}, _dumper, _params) do
    raise "cannot dump invalid changeset"
  end

  def dump(%Ecto.Changeset{valid?: true} = changeset, dumper, params) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> autogenerate_id(changeset.action)
    |> dump(dumper, params)
  end

  def dump(%module{} = struct, dumper, %{
        types_metadata: types_metadata,
        type_field_name: type_field_name
      }) do
    case module.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        unless Map.get(struct, key) do
          raise "polymorphic_embed is not able to add an autogenerated key without casting through cast_polymorphic_embed/3"
        end

      {key, _source, :id} ->
        unless Map.get(struct, key) do
          raise ArgumentError,
                "embedded schema `#{inspect(module)}` cannot autogenerate `:id` primary keys, " <>
                  "those are typically used for auto-incrementing constraints. " <>
                  "Maybe you meant to use `:binary_id` instead?"
        end

      _ ->
        nil
    end

    map =
      struct
      |> map_from_struct()
      # use the atom instead of string form for mongodb
      |> Map.put(type_field_name, do_get_polymorphic_type(module, types_metadata))

    dumper.(:map, map)
  end

  def dump(nil, dumper, _params), do: dumper.(:map, nil)

  defp map_from_struct(struct) do
    Ecto.embedded_dump(struct, :json)
  end

  def get_polymorphic_module(schema, field, type_or_data) do
    %{types_metadata: types_metadata, type_field_name: type_field_name} =
      get_field_opts(schema, field)

    case type_or_data do
      map when is_map(map) ->
        get_polymorphic_module_from_map(map, type_field_name, types_metadata)

      type when is_atom(type) or is_binary(type) ->
        get_polymorphic_module_for_type(type, types_metadata)
    end
  end

  defp get_polymorphic_module_from_map(%{} = attrs, type_field_name, types_metadata) do
    if type = Attrs.get(attrs, type_field_name) do
      get_polymorphic_module_for_type(type, types_metadata)
    else
      # check if one list is contained in another
      # Enum.count(contained -- container) == 0
      # contained -- container == []

      types_metadata =
        types_metadata
        |> Enum.filter(&([] != &1.identify_by_fields))

      if types_metadata != [] do
        keys = Map.keys(attrs) |> Enum.map(&to_string/1)

        types_metadata
        |> Enum.find(&([] == &1.identify_by_fields -- keys))
        |> (&(&1 && Map.fetch!(&1, :module))).()
      else
        nil
      end
    end
  end

  defp get_polymorphic_module_for_type(type, types_metadata) do
    get_metadata_for_type(type, types_metadata)
    |> (&(&1 && Map.fetch!(&1, :module))).()
  end

  def get_polymorphic_type(schema, field, module_or_struct) do
    %{types_metadata: types_metadata} = get_field_opts(schema, field)
    do_get_polymorphic_type(module_or_struct, types_metadata)
  end

  defp do_get_polymorphic_type(%module{}, types_metadata),
    do: do_get_polymorphic_type(module, types_metadata)

  defp do_get_polymorphic_type(module, types_metadata) do
    get_metadata_for_module(module, types_metadata)
    |> Map.fetch!(:type)
  end

  @doc """
  Returns the possible types for a given schema and field

  you can call `types/2` like this:
      PolymorphicEmbed.types(MySchema, :contexts)
      #=> [:location, :age, :device]
  """
  def types(schema, field) do
    %{types_metadata: types_metadata} = get_field_opts(schema, field)
    Enum.map(types_metadata, & &1.type)
  end

  defp get_metadata_for_module(module, types_metadata) do
    Enum.find(types_metadata, &(module == &1.module))
  end

  defp get_metadata_for_type(type, types_metadata) do
    type = to_string(type)
    Enum.find(types_metadata, &(type == to_string(&1.type)))
  end

  @doc false
  def get_field_opts(schema, field) do
    try do
      schema.__schema__(:type, field)
    rescue
      _ in UndefinedFunctionError ->
        reraise ArgumentError, "#{inspect(schema)} is not an Ecto schema", __STACKTRACE__
    else
      {:parameterized, {PolymorphicEmbed, options}} -> Map.put(options, :array?, false)
      {:array, {:parameterized, {PolymorphicEmbed, options}}} -> Map.put(options, :array?, true)
      {_, {:parameterized, {PolymorphicEmbed, options}}} -> Map.put(options, :array?, false)
      nil -> raise ArgumentError, "#{field} is not a polymorphic embed"
    end
  end

  defp raise_if_invalid_options(field, %{array?: array?, default: default, on_replace: on_replace}) do
    if array? and default != [] do
      raise "`:default` option for list of polymorphic embeds is required and must be set to `[]`"
    end

    if array? and on_replace != :delete do
      raise ArgumentError,
            "`:on_replace` option for field #{inspect(field)} must be set to `:delete`"
    end

    if not array? and on_replace != :update do
      raise ArgumentError,
            "`:on_replace` option for field #{inspect(field)} must be set to `:update`"
    end
  end

  defp raise_cannot_infer_type_from_data(data),
    do: raise("could not infer polymorphic embed from data #{inspect(data)}")

  def traverse_errors(%Ecto.Changeset{changes: changes, types: types} = changeset, msg_func)
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    changeset
    |> Ecto.Changeset.traverse_errors(msg_func)
    |> merge_polymorphic_keys(changes, types, msg_func)
  end

  # We need to match the case where an invalid changeset has a PolymorphicEmbed field which is valid,
  # then that PolymorphicEmbed field is already converted to a struct and no longer a changeset.
  # Since the said field is converted to a struct there's errors to check for.
  def traverse_errors(%_{}, msg_func)
      when is_function(msg_func, 1) or is_function(msg_func, 3) do
    %{}
  end

  defp merge_polymorphic_keys(map, changes, types, msg_func) do
    Enum.reduce(types, map, &polymorphic_key_reducer(&1, &2, changes, msg_func))
  end

  defp polymorphic_key_reducer(
         {field, {rel, %{cardinality: :one}}},
         acc,
         changes,
         msg_func
       )
       when rel in [:assoc, :embed] do
    if changeset = Map.get(changes, field) do
      case traverse_errors(changeset, msg_func) do
        errors when errors == %{} -> acc
        errors -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {:parameterized, {PolymorphicEmbed, _opts}}},
         acc,
         changes,
         msg_func
       ) do
    if changeset = Map.get(changes, field) do
      case traverse_errors(changeset, msg_func) do
        errors when errors == %{} -> acc
        errors -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {rel, %{cardinality: :many}}},
         acc,
         changes,
         msg_func
       )
       when rel in [:assoc, :embed] do
    if changesets = Map.get(changes, field) do
      {errors, all_empty?} =
        Enum.map_reduce(changesets, true, fn changeset, all_empty? ->
          errors = traverse_errors(changeset, msg_func)
          {errors, all_empty? and errors == %{}}
        end)

      case all_empty? do
        true -> acc
        false -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer(
         {field, {:array, {:parameterized, {PolymorphicEmbed, _opts}}}},
         acc,
         changes,
         msg_func
       ) do
    if changesets = Map.get(changes, field) do
      {errors, all_empty?} =
        Enum.map_reduce(changesets, true, fn changeset, all_empty? ->
          errors = traverse_errors(changeset, msg_func)
          {errors, all_empty? and errors == %{}}
        end)

      case all_empty? do
        true -> acc
        false -> Map.put(acc, field, errors)
      end
    else
      acc
    end
  end

  defp polymorphic_key_reducer({_, _}, acc, _, _), do: acc

  defp autogenerate_id([], _action), do: []

  defp autogenerate_id([schema | rest], action) do
    [autogenerate_id(schema, action) | autogenerate_id(rest, action)]
  end

  # nil, and plain maps that the load options keep, have no id to generate.
  defp autogenerate_id(value, _action) when not is_struct(value), do: value

  defp autogenerate_id(schema, :update) do
    # in case there is no primary key, Ecto.primary_key/1 returns an empty keyword list []
    for {_, nil} <- Ecto.primary_key(schema) do
      raise("no primary key found in #{inspect(schema)}")
    end

    schema
  end

  defp autogenerate_id(schema, action) when action in [nil, :insert] do
    case schema.__struct__.__schema__(:autogenerate_id) do
      {key, _source, :binary_id} ->
        if Map.get(schema, key) == nil do
          Map.put(schema, key, Ecto.UUID.generate())
        else
          schema
        end

      # As in Ecto, the cast keeps an integer id. Ecto raises on insert, see dump/3.
      {_key, _source, :id} ->
        schema

      nil ->
        schema
    end
  end
end
