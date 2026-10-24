# Changelog

## Unreleased

  `cast_polymorphic_embed/3` now gives the same output as `Ecto.Changeset.cast_embed/3`
  for the same input.

  **Features**:

  * Add `PolymorphicEmbed.put_polymorphic_embed/3`. It works as
    `Ecto.Changeset.put_embed/4`, and it accepts children of all the types of the
    field, also in one list.

  **Breaking changes**:

  * `changeset.changes` keeps each child as an `Ecto.Changeset`, as for an Ecto embed.
    Before, a valid child was a struct. `get_change/2` gives changesets now.
    `apply_changes/1`, `apply_action/2` and `get_field/2` still give structs.
  * `Ecto.Changeset.merge/2` takes the types of the second changeset. Put the changeset of
    `cast_polymorphic_embed/3` second, for example `merge(change(parent), changeset)`.
    Else `get_field/2` and `apply_changes/1` give the child changesets.
  * The repo runs the `prepare_changes/2` functions of the children, as for Ecto embeds.
    Before, the cast lost them. If such a function makes a child invalid, the insert or
    update raises `ArgumentError`, as in Ecto.
  * Ordinary Ecto embeds inside a polymorphic embed get ids and timestamps when the
    repo inserts or updates the parent, as Ecto embeds do. Before, their ids stayed
    `nil`.
  * A list of embeds gets a changeset with action `:replace` for each row of the data
    that the params do not keep. Before, the row was removed from the list.
  * A list of embeds matches the rows of the data by primary key. Before, no row
    matched params with string keys, so each row got a new id and lost the data that
    the params did not set.
  * When the params do not contain the field, the cast does not put the data into
    `changes`.
  * A child that is valid, has action `:update` and has no changes is not a change.
  * When the cast puts changesets into the changes of the field, `changeset.types` has an
    `:embed` type for it. For example, `validate_required/3` on the field then shows the
    same warning as for an Ecto embed.
  * After the cast puts changesets into the changes of the field,
    `Ecto.Changeset.put_change/3`, `update_change/3` and `change/2` accept only one
    schema module for the field, as for an Ecto embed. Before, they accepted all types.
    Use `PolymorphicEmbed.put_polymorphic_embed/3` for children of other types.
  * `nil` for a list of embeds gives the error "is invalid". Before, the cast ignored it.
  * With `required: true`, an empty list in the data gives "can't be blank", and
    `changeset.required` contains the field.
  * An invalid `:on_replace` option raises `ArgumentError`, not `RuntimeError`.
  * The forms of `polymorphic_embed_inputs_for` give the same output as `inputs_for`
    for an Ecto embed:
    * Each form gets the params of its own row. Before, the first row of a list got
      the params of all rows, and the other rows got no params.
    * `form.source` is the child changeset with its action. Before, it was a new
      changeset with the parent action.
    * `form.hidden` contains the primary key of the data, so the form sends the id
      back.
    * A form for an embed that is `nil` uses the changeset function. With a parent
      action, it shows the errors of that changeset.
    * The child forms take the parent action from the form, as in phoenix_ecto. Before,
      `PolymorphicEmbed.HTML.Helpers.to_form/4` took it from the changeset argument.

## 5.0.2

  * Remove warning when aliases cannot be expanded (#123).

## 5.0.1

  * Relax `phoenix_live_view` constraint to allow 1.0.

## 5.0.x

  * Fix usage with Ecto 3.12. Require Ecto 3.12 or later
  * Allow inferring type from parent field via new :use_parent_field_for_type option

## 4.1.x

  * Add `Form.source_data/1` and `Form.source_module/1` (`get_polymorphic_type/2` doesn't work for list of embeds)
  * Add `:retain_unlisted_types_on_load` and `:nilify_unlisted_types_on_load` options
  * MongoDB fix
  * Deprecate `:type_field` in favor of `:type_field_name`

## 4.0.x

  * Support `sort_param` and `drop_param` for list of embeds
  * Add `PolymorphicEmbed.HTML.Component.polymorphic_embed_inputs_for/1`
    (similar to `Phoenix.Component.inputs_for/1`)
  * Support updating list of embeds while retaining ids
  * Fix form input rendering for list of embeds
  * Fix `traverse_errors` for nested embeds

  **Breaking Change**: The form helper `get_polymorphic_type/3` has been updated to `get_polymorphic_type/2`.
  The module name parameter (previously the second parameter) has been removed.

## 3.0.x

  * Default value for polymorphic list of embeds is `[]` instead of `nil` (following `embeds_many/3`)
  * Support Phoenix HTML 4.0
  * Avoid compile-time dependencies between parent and polymorphic embedded schemas

### Migration from 2.x to 3.x

  * Use `polymorphic_embeds_one/2` and `polymorphic_embeds_many/2` macros instead of `field/3`

## 2.0.x

  * Support IDs

### Migration from 1.x to 2.x

  * Make sure that every existing polymorphic `embedded_schema` contains the setting `@primary_key false`

## 1.10.x

  * Add `polymorphic_embed_inputs_for/2` for displaying forms in LiveView
  * Add `polymorphic_embed_inputs_for/3` for displaying forms in Phoenix templates without
    needing to specify the type

## 1.9.x

  * Add `PolymorphicEmbed.types/2` function returning the possible types for a polymorphic field

## 1.8.x

  * Add `:nilify` and `:ignore` for `:on_type_not_found` option

## 1.7.x

  * Support the SQLite3 Ecto adapter `ecto_sqlite3`

## 1.6.x

  * Fix errors in form for `embeds_one` nested into `polymorphic_embed`
  * Refactor `PolymorphicEmbed.HTML.Form`

## 1.5.x

  * Add `traverse_errors/2`

## 1.4.x

  * Support custom changeset functions through `:with` option

## 1.3.x

  * Add `:required` option

## 1.2.x

  * Support custom type field

## 1.1.x

  * Support list of polymorphic embeds
  * Force `:on_replace` option to be explicitly set
