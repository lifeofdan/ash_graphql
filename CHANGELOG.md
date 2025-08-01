# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v1.8.0](https://github.com/ash-project/ash_graphql/compare/v1.7.17...v1.8.0) (2025-07-17)




### Features:

* add domain-level pubsub configuration for subscriptions (#341) by [@barnabasJ](https://github.com/barnabasJ)

## [v1.7.17](https://github.com/ash-project/ash_graphql/compare/v1.7.16...v1.7.17) (2025-07-02)




### Bug Fixes:

* fix :none relationship pagination strategy, and improve tests for it (#337) by Jesse Williams

## [v1.7.16](https://github.com/ash-project/ash_graphql/compare/v1.7.15...v1.7.16) (2025-07-02)




### Bug Fixes:

* Add sorting of managed inputs to output stable graphql schema (#334) by olivermt

## [v1.7.15](https://github.com/ash-project/ash_graphql/compare/v1.7.14...v1.7.15) (2025-06-18)




### Bug Fixes:

* Fix nil constraint to non_null mapping for complex subtypes used in :array definitions (#329) by olivermt

### Improvements:

* Add sortable_fields option (#331) by [@jechol](https://github.com/jechol)

* add a verifier for argument types option by [@zachdaniel](https://github.com/zachdaniel)

## [v1.7.14](https://github.com/ash-project/ash_graphql/compare/v1.7.13...v1.7.14) (2025-06-10)




### Bug Fixes:

* handling of attribute with array type in middleware for field function (#327) by [@jichon](https://github.com/jichon)

## [v1.7.13](https://github.com/ash-project/ash_graphql/compare/v1.7.12...v1.7.13) (2025-05-30)




### Bug Fixes:

* properly unwrap constraints & type for list newtypes

### Improvements:

* add limit to pagination metadata (#323)

* support new codegen patterns

* make pagination metadata more robust for offeset pagination (#320)

## [v1.7.12](https://github.com/ash-project/ash_graphql/compare/v1.7.11...v1.7.12) (2025-05-22)




### Bug Fixes:

* change default playground interface (#319)

## [v1.7.11](https://github.com/ash-project/ash_graphql/compare/v1.7.10...v1.7.11) (2025-05-20)




### Improvements:

* Add meta option for adding custom resolution context (#317)

## [v1.7.10](https://github.com/ash-project/ash_graphql/compare/v1.7.9...v1.7.10) (2025-05-15)




### Bug Fixes:

* refactor internal `AshGraphql.Resource.mutation/6` (#312)

* refactor internal `AshGraphql.Resource.mutation_fields/5` (#311)

* define shared mutations options (#310)

* Support for returning relay encoded id when subscribing to destroy events (#307)

### Improvements:

* add `args` option to mutations (#314)

## [v1.7.9](https://github.com/ash-project/ash_graphql/compare/v1.7.8...v1.7.9) (2025-04-29)




### Bug Fixes:

* properly expand lazy nested types

* handle invalid query error different formats (#301)

### Improvements:

* add `authorize_update_destroy_with_error?` config

* use more descriptions from resources

## [v1.7.8](https://github.com/ash-project/ash_graphql/compare/v1.7.7...v1.7.8) (2025-04-15)




### Bug Fixes:

* Add domain to Ash.for_read, as it might not be set on the resource, but only by set_domain middleware (for `use Ash.Resource domain: nil`). (#300)

## [v1.7.7](https://github.com/ash-project/ash_graphql/compare/v1.7.6...v1.7.7) (2025-04-09)




### Bug Fixes:

* more fixes for compilation loops

### Improvements:

* allows :logger handlers to know the original exception (#297)

## [v1.7.6](https://github.com/ash-project/ash_graphql/compare/v1.7.5...v1.7.6) (2025-03-21)




### Bug Fixes:

* allow for calculations & args in filter and use filter/sort_input

## [v1.7.5](https://github.com/ash-project/ash_graphql/compare/v1.7.4...v1.7.5) (2025-03-20)




### Bug Fixes:

* logic error in union type resolution

* resolve arrays of unions and unions of arrays properly

* properly extract item constraints when resolving union results

## [v1.7.4](https://github.com/ash-project/ash_graphql/compare/v1.7.3...v1.7.4) (2025-03-18)




### Bug Fixes:

* properly construct nested type maps

* apply action verifier to domains as well as resources

* Properly non_null() inner items in list when constraint is supplied for arrays in NewType of :map (#286)

## [v1.7.3](https://github.com/ash-project/ash_graphql/compare/v1.7.2...v1.7.3) (2025-03-04)




### Bug Fixes:

* fully traverse nested map & union types

## [v1.7.2](https://github.com/ash-project/ash_graphql/compare/v1.7.1...v1.7.2) (2025-02-27)




### Bug Fixes:

* add `use Absinthe.Phoenix.Socket` in endpoints in installer

## [v1.7.1](https://github.com/ash-project/ash_graphql/compare/v1.7.0...v1.7.1) (2025-02-27)




### Bug Fixes:

* properly add absinthe_phoenix dependency in installer

## [v1.7.0](https://github.com/ash-project/ash_graphql/compare/v1.6.0...v1.7.0) (2025-02-25)




### Features:

* subscription installer (#266)

### Improvements:

* don't require object unless there is a reason

* add `auto_generate_sdl_file?` option to graphql schema

## [v1.6.0](https://github.com/ash-project/ash_graphql/compare/v1.5.1...v1.6.0) (2025-02-11)




### Features:

* Type and Query complexity callbacks (#273)

* Type and Query complexity callbacks

### Bug Fixes:

* handle actions with no return

## [v1.5.1](https://github.com/ash-project/ash_graphql/compare/v1.5.0...v1.5.1) (2025-01-27)




### Bug Fixes:

* make manage relationship fields nullable when not always required

* default error handling (#261)

## [v1.5.0](https://github.com/ash-project/ash_graphql/compare/v1.4.7...v1.5.0) (2025-01-10)




### Features:

* errors: carry action name in context (#257)

### Improvements:

* error handling in resources (#253)

## [v1.4.7](https://github.com/ash-project/ash_graphql/compare/v1.4.6...v1.4.7) (2024-12-20)




### Improvements:

* add `modify_resolution` for generic actions

* make igniter optional

## [v1.4.6](https://github.com/ash-project/ash_graphql/compare/v1.4.5...v1.4.6) (2024-12-11)




### Bug Fixes:

* fix docs & return type for generic actions

## [v1.4.5](https://github.com/ash-project/ash_graphql/compare/v1.4.4...v1.4.5) (2024-12-11)

### Improvements:

- support `error_location` option on generic actions

- add description to update and destroy mutations (#250)

## [v1.4.4](https://github.com/ash-project/ash_graphql/compare/v1.4.3...v1.4.4) (2024-12-02)

### Bug Fixes:

- don't assume required pagination in actions means relationships are paginated

- define `subscription` to handle case where no subscriptions exist

- load relationships and calculations in fragments (#246)

## [v1.4.3](https://github.com/ash-project/ash_graphql/compare/v1.4.2...v1.4.3) (2024-11-14)

### Improvements:

- Implement `AshGraphql.Error` for AshAuthentication errors. (#237)

- Support generic actions without a return type. (#238)

## [v1.4.2](https://github.com/ash-project/ash_graphql/compare/v1.4.1...v1.4.2) (2024-11-05)

### Bug Fixes:

- call `for_read` before adding calculations

- load fields after building query for action

## [v1.4.1](https://github.com/ash-project/ash_graphql/compare/v1.4.0...v1.4.1) (2024-10-21)

### Bug Fixes:

- honor argument_names configuration for read & generic actions

### Improvements:

- remove unused data in subscription batcher (#227)

## [v1.4.0](https://github.com/ash-project/ash_graphql/compare/v1.3.4...v1.4.0) (2024-10-09)

### Features:

- Add absinthe dependency and plugin in formatter of installer (#222)

- subscription dsl (#97)

### Bug Fixes:

- dyalizer and igniter deprecations (#224)

- don't generate result types for generic mutations

- detect generated types properly in generic actions

### Improvements:

- add error handling tooling for custom queries

- add `AshGraphql.load_fields/3` helper, and test showing its usage

- implement a subscription notification batcher (#217)

## [v1.3.4](https://github.com/ash-project/ash_graphql/compare/v1.3.3...v1.3.4) (2024-09-10)

### Bug Fixes:

- add UUIDv7 to map the type to :id

### Improvements:

- update to latest igniter functions & dependency

## [v1.3.3](https://github.com/ash-project/ash_graphql/compare/v1.3.2...v1.3.3) (2024-08-26)

### Bug Fixes:

- append new domain to list when extending

## [v1.3.2](https://github.com/ash-project/ash_graphql/compare/v1.3.1...v1.3.2) (2024-08-16)

### Bug Fixes:

- match on action in error message properly

### Improvements:

- add schema codegen features & guide

- support new struct types in type generation

- support new struct fields constraint

- Set up GraphQL schema file in the web module namespace (#205)

## [v1.3.1](https://github.com/ash-project/ash_graphql/compare/v1.3.0...v1.3.1) (2024-08-02)

### Bug Fixes:

- use `.has_expression?/0` instead of `function_exported?/3`

- error handling list of atoms (#204)

- error handling list of atoms

## [v1.3.0](https://github.com/ash-project/ash_graphql/compare/v1.2.1...v1.3.0) (2024-08-01)

### Features:

- `Ash.Type.File` compatibility (#202)

### Bug Fixes:

- try to resolve compilation issues w/ `Code.ensure_compiled!`

## [v1.2.1](https://github.com/ash-project/ash_graphql/compare/v1.2.0...v1.2.1) (2024-07-18)

### Bug Fixes:

- upgrade ash dependency for bulk action bug fix

- use checked constraints (#187)

- don't assume `filter` is non-nil for gets

- properly interpolate action in conflict messages

- add resource query to action struct (#178)

### Improvements:

- add extension installation code

- add igniter-backed installer

- add `nullable_fields?` for easily marking fields as nullable

- only define `managed_relationship` mutations when necessary

## [v1.2.0](https://github.com/ash-project/ash_graphql/compare/v1.1.1...v1.2.0) (2024-06-17)

### Features:

- argument_input_types (#176)

- argument_input_types

### Bug Fixes:

- better type handling around empty types

- don't generate empty input objects for embeds

## [v1.1.1](https://github.com/ash-project/ash_graphql/compare/v1.1.0...v1.1.1) (2024-06-02)

### Features:

- relationship pagination (#166)

### Bug Fixes:

- honor read_action for update/destroy mutations

## [v1.1.0](https://github.com/ash-project/ash_graphql/compare/v1.0.1...v1.1.0) (2024-05-24)

### Features:

- [AshGraphql.Domain] support queries/mutations on the domain

## [v1.0.1](https://github.com/ash-project/ash_graphql/compare/v1.0.0...v1.0.1) (2024-05-23)

### Features:

- allow passing custom descriptions to queries and mutations (#138)

### Bug Fixes:

- don't deduplicate argument types by argument name (#162)

- use Ash.EmbeddableType.ShadowDomain (#156)

- accepted attributes don't have to be `public?`

### Improvements:

- deduplicate map types across domains (#164)

- Implement AshGraphql.Error for Ash.Error.Query.ReadActionRequiresActor (#154)

- make mutation result errors list non-nullable (#144)

- make mutation result errors list non-nullable

## [v1.0.0](https://github.com/ash-project/ash_graphql/compare/v1.0.0-rc.4...v0.28.0) (2024-04-27)

The changelog is being restarted. See `/documentation/1.0-CHANGELOG.md` for previous changelogs.

### Breaking Changes:

- [AshGraphql.Resource] `managed_relationship` arguments automatically get rich types derived for them
- [AshGraphql.Type] No longer automagically derive types. Only types defined in `Ash.Type.NewType` that implement `AshGrahql.Type` will get types derived for them.

### Improvements:

- [AshGraphql.Resolver] Bulk actions are automatically used for create/update/destroy actions. This means far fewer queries made in general.
- [AshGraphql.Type] add `graphql_define_type?/1` callback for graphql types
- [AshGrapqhl.Resource] support generic actions with no return type
