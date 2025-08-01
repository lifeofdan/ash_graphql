defmodule AshGraphql.Graphql.Resolver do
  @moduledoc false

  require Logger
  import Ash.Expr
  require Ash.Query
  import AshGraphql.TraceHelpers
  import AshGraphql.ContextHelpers

  def resolve(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve(
        %{arguments: arguments, context: context} = resolution,
        {domain, resource,
         %AshGraphql.Resource.Action{
           name: query_name,
           action: action,
           modify_resolution: modify,
           error_location: error_location
         }, mutation_args}
      ) do
    action = Ash.Resource.Info.action(resource, action)

    arguments_result =
      if mutation_args do
        handle_mutation_arguments(resource, action, nil, arguments, mutation_args)
      else
        handle_arguments(resource, action, arguments)
      end

    case arguments_result do
      {:ok, arguments} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          source: :graphql,
          query: query_name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_query,
              query_name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            domain: domain,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant)
          ]

          input =
            %Ash.ActionInput{domain: domain, resource: resource}
            |> Ash.ActionInput.set_context(get_context(context))
            |> Ash.ActionInput.for_action(action.name, arguments)

          result =
            input
            |> Ash.run_action(opts)
            |> case do
              :ok ->
                {:ok, true}

              {:ok, result} ->
                load_opts =
                  [
                    actor: Map.get(context, :actor),
                    action: action,
                    domain: domain,
                    authorize?: AshGraphql.Domain.Info.authorize?(domain),
                    tenant: Map.get(context, :tenant)
                  ]

                if action.returns && Ash.Type.can_load?(action.returns, action.constraints) do
                  {fields, path} = nested_fields_and_path(resolution, [], [])

                  loads =
                    type_loads(
                      fields,
                      context,
                      action.returns,
                      action.constraints,
                      load_opts,
                      resource,
                      action.name,
                      resolution,
                      path,
                      hd(resolution.path),
                      nil
                    )

                  case loads do
                    [] ->
                      {:ok, result}

                    loads ->
                      Ash.Type.load(
                        action.returns,
                        result,
                        loads,
                        action.constraints,
                        Map.new(load_opts)
                      )
                  end
                else
                  {:ok, result}
                end

              {:error, error} ->
                {:error, error}
            end

          modify_args = [input, result]

          result =
            if error_location == :in_result do
              case result do
                {:ok, result} ->
                  {:ok, %{result: result, errors: []}}

                {:error, errors} ->
                  {:ok,
                   %{result: nil, errors: to_errors(errors, context, domain, resource, action)}}
              end
            else
              result
            end

          resolution
          |> Absinthe.Resolution.put_result(
            to_resolution(
              result,
              context,
              domain
            )
          )
          |> add_root_errors(domain, resource, action, result)
          |> modify_resolution(modify, modify_args)
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        Absinthe.Resolution.put_result(
          resolution,
          to_resolution({:error, error}, context, domain)
        )
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def resolve(
        %{arguments: arguments, context: context} = resolution,
        {domain, resource,
         %{
           name: query_name,
           type: :get,
           action: action,
           identity: identity,
           type_name: type_name,
           modify_resolution: modify
         } = gql_query, relay_ids?}
      ) do
    case handle_arguments(resource, action, arguments) do
      {:ok, arguments} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          source: :graphql,
          query: query_name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_query,
              query_name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            action: action,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant)
          ]

          filter = identity_filter(identity, resource, arguments, relay_ids?)

          query =
            resource
            |> Ash.Query.new()
            |> Ash.Query.set_tenant(Map.get(context, :tenant))
            |> Ash.Query.set_context(get_context(context))
            |> set_query_arguments(action, arguments)
            |> select_fields(resource, resolution, type_name)

          {result, modify_args} =
            case filter do
              {:ok, filter} ->
                query = Ash.Query.do_filter(query, filter)

                result =
                  query
                  |> Ash.Query.for_read(action, %{},
                    actor: opts[:actor],
                    authorize?: AshGraphql.Domain.Info.authorize?(domain),
                    tenant: Map.get(context, :tenant),
                    tracer: AshGraphql.Domain.Info.tracer(domain),
                    domain: domain
                  )
                  |> load_fields(
                    [
                      domain: domain,
                      tenant: Map.get(context, :tenant),
                      authorize?: AshGraphql.Domain.Info.authorize?(domain),
                      tracer: AshGraphql.Domain.Info.tracer(domain),
                      actor: Map.get(context, :actor)
                    ],
                    resource,
                    resolution,
                    resolution.path,
                    context,
                    type_name
                  )
                  |> Ash.read_one(opts)

                {result, [query, result]}

              {:error, error} ->
                query =
                  resource
                  |> Ash.Query.new()
                  |> Ash.Query.set_tenant(Map.get(context, :tenant))
                  |> Ash.Query.set_context(get_context(context))
                  |> set_query_arguments(action, arguments)
                  |> select_fields(resource, resolution, type_name)
                  |> load_fields(
                    [
                      domain: domain,
                      tenant: Map.get(context, :tenant),
                      authorize?: AshGraphql.Domain.Info.authorize?(domain),
                      tracer: AshGraphql.Domain.Info.tracer(domain),
                      actor: Map.get(context, :actor)
                    ],
                    resource,
                    resolution,
                    resolution.path,
                    context,
                    type_name
                  )

                {{:error, error}, [query, {:error, error}]}
            end

          case {result, gql_query.allow_nil?} do
            {{:ok, nil}, false} ->
              {:ok, filter} = filter

              error =
                Ash.Error.Query.NotFound.exception(
                  primary_key: Map.new(filter || []),
                  resource: resource
                )

              resolution
              |> Absinthe.Resolution.put_result(
                {:error, to_errors([error], context, domain, resource, action)}
              )
              |> add_root_errors(domain, resource, action, result)

            {result, _} ->
              resolution
              |> Absinthe.Resolution.put_result(
                to_resolution(
                  result
                  |> add_read_metadata(
                    gql_query,
                    Ash.Resource.Info.action(query.resource, action)
                  ),
                  context,
                  domain
                )
              )
              |> add_root_errors(domain, resource, action, result)
              |> modify_resolution(modify, modify_args)
          end
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        Absinthe.Resolution.put_result(
          resolution,
          to_resolution({:error, error}, context, domain)
        )
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def resolve(
        %{arguments: args, context: context} = resolution,
        {domain, resource,
         %{
           name: query_name,
           type: :read_one,
           action: action,
           modify_resolution: modify,
           type_name: type_name
         } =
           gql_query, _relay_ids?}
      ) do
    metadata = %{
      domain: domain,
      resource: resource,
      resource_short_name: Ash.Resource.Info.short_name(resource),
      actor: Map.get(context, :actor),
      tenant: Map.get(context, :tenant),
      action: action,
      source: :graphql,
      query: query_name,
      authorize?: AshGraphql.Domain.Info.authorize?(domain)
    }

    with {:ok, args} <- handle_arguments(resource, action, args),
         {:ok, query} <- read_one_query(resource, args) do
      trace domain,
            resource,
            :gql_query,
            query_name,
            metadata do
        opts = [
          actor: Map.get(context, :actor),
          action: action,
          authorize?: AshGraphql.Domain.Info.authorize?(domain),
          tenant: Map.get(context, :tenant)
        ]

        query =
          query
          |> Ash.Query.set_tenant(Map.get(context, :tenant))
          |> Ash.Query.set_context(get_context(context))
          |> set_query_arguments(action, args)
          |> select_fields(resource, resolution, type_name)
          |> Ash.Query.for_read(action, %{},
            actor: opts[:actor],
            domain: domain,
            authorize?: AshGraphql.Domain.Info.authorize?(domain)
          )
          |> load_fields(
            [
              domain: domain,
              tenant: Map.get(context, :tenant),
              authorize?: AshGraphql.Domain.Info.authorize?(domain),
              tracer: AshGraphql.Domain.Info.tracer(domain),
              actor: Map.get(context, :actor)
            ],
            resource,
            resolution,
            resolution.path,
            context,
            type_name
          )

        result =
          Ash.read_one(query, opts)

        result =
          add_read_metadata(
            result,
            gql_query,
            Ash.Resource.Info.action(query.resource, action)
          )

        resolution
        |> Absinthe.Resolution.put_result(to_resolution(result, context, domain))
        |> add_root_errors(domain, resource, action, result)
        |> modify_resolution(modify, [query, args])
      end
    else
      {:error, error} ->
        resolution
        |> Absinthe.Resolution.put_result(to_resolution({:error, error}, context, domain))
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        Absinthe.Resolution.put_result(
          resolution,
          to_resolution({:error, error}, context, domain)
        )
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def resolve(
        %{arguments: args, context: context} = resolution,
        {domain, resource,
         %{
           name: query_name,
           type: :list,
           relay?: relay?,
           action: action,
           type_name: type_name,
           modify_resolution: modify
         } = gql_query, _relay_ids?}
      ) do
    case handle_arguments(resource, action, args) do
      {:ok, args} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          source: :graphql,
          query: query_name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_query,
              query_name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            action: action,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant)
          ]

          pagination = Ash.Resource.Info.action(resource, action).pagination
          query = apply_load_arguments(args, Ash.Query.new(resource), true)

          {result, modify_args} =
            with {:ok, opts} <-
                   validate_resolve_opts(
                     resolution,
                     resource,
                     pagination,
                     relay?,
                     opts,
                     args,
                     gql_query,
                     action
                   ),
                 result_fields <-
                   get_result_fields(
                     AshGraphql.Resource.query_pagination_strategy(
                       gql_query,
                       Ash.Resource.Info.action(resource, action)
                     ),
                     relay?
                   ),
                 query <-
                   query
                   |> Ash.Query.set_tenant(Map.get(context, :tenant))
                   |> Ash.Query.set_context(get_context(context))
                   |> set_query_arguments(action, args)
                   |> select_fields(resource, resolution, type_name, result_fields),
                 query <-
                   query
                   |> Ash.Query.for_read(action, %{},
                     actor: Map.get(context, :actor),
                     domain: domain,
                     authorize?: AshGraphql.Domain.Info.authorize?(domain)
                   ),
                 query <-
                   load_fields(
                     query,
                     [
                       domain: domain,
                       tenant: Map.get(context, :tenant),
                       authorize?: AshGraphql.Domain.Info.authorize?(domain),
                       tracer: AshGraphql.Domain.Info.tracer(domain),
                       actor: Map.get(context, :actor)
                     ],
                     resource,
                     resolution,
                     resolution.path,
                     context,
                     type_name,
                     result_fields
                   ),
                 {:ok, page} <- Ash.read(query, opts) do
              result = paginate(resource, gql_query, action, page, relay?)
              {result, [query, result]}
            else
              {:error, error} ->
                {{:error, error}, [query, {:error, error}]}
            end

          result =
            add_read_metadata(result, gql_query, Ash.Resource.Info.action(query.resource, action))

          resolution
          |> Absinthe.Resolution.put_result(to_resolution(result, context, domain))
          |> add_root_errors(domain, resource, action, modify_args)
          |> modify_resolution(modify, modify_args)
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        Absinthe.Resolution.put_result(
          resolution,
          to_resolution({:error, error}, context, domain)
        )
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def resolve(
        %{root_value: {:pre_resolved, item}} = resolution,
        {_, _, %AshGraphql.Resource.Subscription{}, _}
      ) do
    Absinthe.Resolution.put_result(
      resolution,
      {:ok, item}
    )
  end

  def resolve(
        %{arguments: args, context: context, root_value: notifications} = resolution,
        {domain, resource,
         %AshGraphql.Resource.Subscription{read_action: read_action, name: name}, relay_ids?}
      )
      when is_list(notifications) do
    case handle_arguments(resource, read_action, args) do
      {:ok, args} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: read_action,
          source: :graphql,
          subscription: name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_subscription,
              name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            action: read_action,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant)
          ]

          subscription_events =
            notifications
            |> Enum.group_by(& &1.action_type)
            |> Enum.map(fn {type, notifications} ->
              subscription_field = subcription_field_from_action_type(type)
              key = String.to_existing_atom(subscription_field)

              if type in [:create, :update] do
                data = Enum.map(notifications, & &1.data)
                {filter, args} = Map.pop(args, :filter)

                read_action =
                  read_action || Ash.Resource.Info.primary_action!(resource, :read).name

                # read the records that were just created/updated
                query =
                  resource
                  |> Ash.Query.do_filter(massage_filter(resource, filter))
                  |> Ash.Query.for_read(read_action, args, opts)
                  |> AshGraphql.Subscription.query_for_subscription(
                    domain,
                    resolution,
                    subscription_result_type(name),
                    [subscription_field]
                  )

                query_with_authorization_rules =
                  Ash.can(
                    query,
                    opts[:actor],
                    tenant: opts[:tenant],
                    run_queries?: false,
                    alter_source?: true
                  )

                current_filter = query.filter

                {known_results, need_refetch} =
                  case query_with_authorization_rules do
                    {:ok, true, %{authorize_results: [], filter: nil} = query} ->
                      {data, []}

                    {:ok, true,
                     %{authorize_results: [], filter: %Ash.Filter{expression: nil}} = query} ->
                      {data, []}

                    {:ok, true, %{authorize_results: []} = query} ->
                      Enum.reduce(data, {[], []}, fn record, {known, refetch} ->
                        case Ash.Expr.eval(query.filter,
                               record: data,
                               unknown_on_unknown_refs?: true
                             ) do
                          {:ok, true} ->
                            {[record | known], refetch}

                          {:ok, false} ->
                            {known, refetch}

                          _ ->
                            {known, [record | refetch]}
                        end
                      end)

                    {:error, false, _} ->
                      {[], []}

                    _ ->
                      {[], data}
                  end

                primary_key = Ash.Resource.Info.primary_key(resource)

                primary_key_matches =
                  Enum.map(need_refetch, fn record ->
                    Map.take(record, primary_key)
                  end)

                with {:ok, known_results} <- Ash.load(known_results, query),
                     {:ok, need_refetch} <- do_refetch(query, primary_key_matches) do
                  known_results
                  |> Stream.concat(need_refetch)
                  |> Enum.map(fn record ->
                    %{key => record}
                  end)
                else
                  {:error, error} ->
                    # caught by the batch resolver
                    raise Ash.Error.to_error_class(error)
                end
              else
                Enum.map(notifications, fn notification ->
                  %{key => AshGraphql.Resource.encode_id(notification.data, relay_ids?)}
                end)
              end
            end)

          case List.flatten(subscription_events) do
            [] ->
              Absinthe.Resolution.put_result(
                resolution,
                {:error,
                 to_errors(
                   [Ash.Error.Query.NotFound.exception()],
                   context,
                   domain,
                   resource,
                   read_action
                 )}
              )

            [first | rest] ->
              Process.put(:batch_resolved, rest)

              Absinthe.Resolution.put_result(
                resolution,
                {:ok, first}
              )
          end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def resolve(
        %{arguments: args, context: context, root_value: notification} = resolution,
        {domain, resource,
         %AshGraphql.Resource.Subscription{read_action: read_action, name: name}, relay_ids?}
      ) do
    case handle_arguments(resource, read_action, args) do
      {:ok, args} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: read_action,
          source: :graphql,
          subscription: name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_subscription,
              name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            action: read_action,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant)
          ]

          cond do
            notification.action_type in [:create, :update] ->
              data = notification.data
              {filter, args} = Map.pop(args, :filter)

              read_action =
                read_action || Ash.Resource.Info.primary_action!(resource, :read).name

              query =
                Ash.Resource.Info.primary_key(resource)
                |> Enum.reduce(resource, fn key, query ->
                  value = Map.get(data, key)
                  Ash.Query.filter(query, ^ref(key) == ^value)
                end)

              query =
                Ash.Query.do_filter(
                  query,
                  massage_filter(query.resource, filter)
                )

              query =
                AshGraphql.Subscription.query_for_subscription(
                  query
                  |> Ash.Query.for_read(read_action, args, opts),
                  domain,
                  resolution,
                  subscription_result_type(name),
                  [subcription_field_from_action_type(notification.action_type)]
                )

              result =
                with {:ok, true, query} <-
                       Ash.can(
                         query,
                         opts[:actor],
                         tenant: opts[:tenant],
                         run_queries?: false,
                         alter_source?: true
                       ),
                     [] <- query.authorize_results,
                     {:ok, true} <-
                       Ash.Expr.eval(query.filter,
                         record: data,
                         unknown_on_unknown_refs?: true
                       ) do
                  Ash.load(data, query)
                else
                  _ ->
                    query |> Ash.read_one()
                end

              case result do
                # should only happen if a resource is created/updated and the subscribed user is not allowed to see it
                {:ok, nil} ->
                  resolution
                  |> Absinthe.Resolution.put_result(
                    {:error,
                     to_errors(
                       [Ash.Error.Query.NotFound.exception()],
                       context,
                       domain,
                       resource,
                       read_action
                     )}
                  )

                {:ok, result} ->
                  resolution
                  |> Absinthe.Resolution.put_result(
                    {:ok,
                     %{
                       String.to_existing_atom(
                         subcription_field_from_action_type(notification.action_type)
                       ) => result
                     }}
                  )

                {:error, error} ->
                  resolution
                  |> Absinthe.Resolution.put_result(
                    {:error, to_errors([error], context, domain, resource, read_action)}
                  )
              end

            notification.action_type in [:destroy] ->
              resolution
              |> Absinthe.Resolution.put_result(
                {:ok,
                 %{
                   String.to_existing_atom(
                     subcription_field_from_action_type(notification.action_type)
                   ) => AshGraphql.Resource.encode_id(notification.data, relay_ids?)
                 }}
              )
          end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_refetch(_query, []) do
    {:ok, []}
  end

  defp do_refetch(query, primary_key_matches) do
    Ash.read(Ash.Query.do_filter(query, or: primary_key_matches))
  end

  defp subcription_field_from_action_type(:create), do: "created"
  defp subcription_field_from_action_type(:update), do: "updated"
  defp subcription_field_from_action_type(:destroy), do: "destroyed"

  defp read_one_query(resource, args) do
    case Map.fetch(args, :filter) do
      {:ok, filter} when filter != %{} ->
        case Ash.Filter.parse_input(resource, filter) do
          {:ok, parsed} ->
            {:ok, Ash.Query.do_filter(resource, parsed)}

          {:error, error} ->
            {:error, error}
        end

      _ ->
        {:ok, Ash.Query.new(resource)}
    end
  end

  defp handle_mutation_arguments(resource, action, read_action, arguments, mutation_args) do
    {input_argument, arguments} = Map.pop(arguments, :input, %{})
    {mutation_inputs, read_inputs} = Map.split(arguments, mutation_args)
    mutation_inputs = Map.merge(mutation_inputs, input_argument)

    case handle_arguments(resource, action, mutation_inputs) do
      {:ok, mutation_inputs} ->
        if read_action do
          case handle_arguments(resource, read_action, read_inputs) do
            {:ok, read_inputs} ->
              {:ok, mutation_inputs, read_inputs}

            error ->
              error
          end
        else
          {:ok, mutation_inputs}
        end

      error ->
        error
    end
  end

  defp handle_arguments(_resource, nil, argument_values) do
    {:ok, argument_values}
  end

  defp handle_arguments(resource, action, argument_values) when is_atom(action) do
    action = Ash.Resource.Info.action(resource, action)
    handle_arguments(resource, action, argument_values)
  end

  defp handle_arguments(resource, action, argument_values) do
    action_arguments = action.arguments

    attributes =
      resource
      |> Ash.Resource.Info.attributes()

    argument_values
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, arguments} ->
      argument =
        Enum.find(action_arguments, &(&1.name == key)) || Enum.find(attributes, &(&1.name == key))

      if argument do
        %{type: type, name: name, constraints: constraints} = argument

        case handle_argument(resource, action, type, constraints, value, name) do
          {:ok, value} ->
            {:cont, {:ok, Map.put(arguments, name, value)}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      else
        {:cont, {:ok, Map.put(arguments, key, value)}}
      end
    end)
  end

  defp handle_argument(resource, action, {:array, type}, constraints, value, name)
       when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case handle_argument(resource, action, type, constraints[:items], value, name) do
        {:ok, value} ->
          {:cont, {:ok, [value | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, value} -> {:ok, Enum.reverse(value)}
      {:error, error} -> {:error, error}
    end
  end

  defp handle_argument(_resource, _action, Ash.Type.Union, constraints, value, name) do
    handle_union_type(value, constraints, name)
  end

  defp handle_argument(resource, action, type, constraints, value, name) do
    cond do
      AshGraphql.Resource.Info.managed_relationship(resource, action, %{name: name, type: type}) &&
          is_map(value) ->
        managed_relationship =
          AshGraphql.Resource.Info.managed_relationship(resource, action, %{
            name: name,
            type: type
          })

        opts = AshGraphql.Resource.find_manage_change(%{name: name, type: type}, action, resource)

        relationship =
          Ash.Resource.Info.relationship(resource, opts[:relationship]) ||
            raise """
            No relationship found when building managed relationship input: #{opts[:relationship]}
            """

        manage_opts_schema =
          if opts[:opts][:type] do
            defaults = Ash.Changeset.manage_relationship_opts(opts[:opts][:type])

            Enum.reduce(defaults, Ash.Changeset.manage_relationship_schema(), fn {key, value},
                                                                                 manage_opts ->
              Spark.Options.Helpers.set_default!(manage_opts, key, value)
            end)
          else
            Ash.Changeset.manage_relationship_schema()
          end

        manage_opts = Spark.Options.validate!(opts[:opts], manage_opts_schema)

        fields =
          resource
          |> AshGraphql.Resource.manage_fields(
            manage_opts,
            managed_relationship,
            relationship,
            __MODULE__
          )
          |> Enum.reject(fn
            {_, :__primary_key, _} ->
              true

            {_, {:identity, _}, _} ->
              true

            _ ->
              false
          end)
          |> Map.new(fn {_, _, %{identifier: identifier}} = field ->
            {identifier, field}
          end)

        Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          field_name =
            resource
            |> AshGraphql.Resource.Info.field_names()
            |> Enum.map(fn {l, r} -> {r, l} end)
            |> Keyword.get(key, key)

          case Map.get(fields, field_name) do
            nil ->
              {:cont, {:ok, Map.put(acc, key, value)}}

            {resource, action, _} ->
              action = Ash.Resource.Info.action(resource, action)
              attributes = Ash.Resource.Info.public_attributes(resource)

              argument =
                Enum.find(action.arguments, &(&1.name == field_name)) ||
                  Enum.find(attributes, &(&1.name == field_name))

              if argument do
                %{type: type, name: name, constraints: constraints} = argument

                case handle_argument(resource, action, type, constraints, value, name) do
                  {:ok, value} ->
                    {:cont, {:ok, Map.put(acc, key, value)}}

                  {:error, error} ->
                    {:halt, {:error, error}}
                end
              else
                {:cont, {:ok, Map.put(acc, key, value)}}
              end
          end
        end)

      Ash.Type.NewType.new_type?(type) ->
        handle_argument(
          resource,
          action,
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints),
          value,
          name
        )

      AshGraphql.Resource.embedded?(type) and is_map(value) ->
        create_action =
          if constraints[:create_action] do
            Ash.Resource.Info.action(type, constraints[:create_action]) ||
              Ash.Resource.Info.primary_action(type, :create)
          else
            Ash.Resource.Info.primary_action(type, :create)
          end

        update_action =
          if constraints[:update_action] do
            Ash.Resource.Info.action(type, constraints[:update_action]) ||
              Ash.Resource.Info.primary_action(type, :update)
          else
            Ash.Resource.Info.primary_action(type, :update)
          end

        attributes = Ash.Resource.Info.public_attributes(type)

        fields =
          cond do
            create_action && update_action ->
              create_action.arguments ++ update_action.arguments ++ attributes

            update_action ->
              update_action.arguments ++ attributes

            create_action ->
              create_action.arguments ++ attributes

            true ->
              attributes
          end

        value
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          field =
            Enum.find(fields, fn field ->
              field.name == key
            end)

          if field do
            case handle_argument(
                   resource,
                   action,
                   field.type,
                   field.constraints,
                   value,
                   "#{name}.#{key}"
                 ) do
              {:ok, value} ->
                {:cont, {:ok, Map.put(acc, key, value)}}

              {:error, error} ->
                {:halt, {:error, error}}
            end
          else
            {:cont, {:ok, Map.put(acc, key, value)}}
          end
        end)

      true ->
        {:ok, value}
    end
  end

  defp handle_union_type(value, constraints, name) do
    value
    |> Enum.reject(fn {_key, value} ->
      is_nil(value)
    end)
    |> case do
      [] ->
        {:ok, nil}

      [{key, value}] ->
        config = constraints[:types][key]

        if config[:tag] && is_map(value) do
          {:ok,
           %Ash.Union{type: key, value: Map.put_new(value, config[:tag], config[:tag_value])}}
        else
          {:ok, %Ash.Union{type: key, value: value}}
        end

      key_vals ->
        keys = Enum.map_join(key_vals, ", ", fn {key, _} -> to_string(key) end)

        {:error,
         %{message: "Only one key can be specified, but got #{keys}", fields: ["#{name}"]}}
    end
  end

  def validate_resolve_opts(resolution, resource, pagination, relay?, opts, args, query, action) do
    action = Ash.Resource.Info.action(resource, action)

    case AshGraphql.Resource.query_pagination_strategy(query, action) do
      nil ->
        {:ok, opts}

      strategy ->
        with {:ok, page} <- page_opts(resolution, resource, pagination, relay?, args, strategy) do
          {:ok, Keyword.put(opts, :page, page)}
        end
    end
  end

  defp page_opts(resolution, resource, pagination, relay?, args, strategy, nested \\ []) do
    page_opts =
      args
      |> Map.take([:limit, :offset, :first, :after, :before, :last])
      |> Enum.reject(fn {_, val} -> is_nil(val) end)

    with {:ok, page_opts} <- validate_offset_opts(page_opts, strategy, pagination),
         {:ok, page_opts} <- validate_keyset_opts(page_opts, strategy, pagination) do
      type = page_type(resource, strategy, relay?)

      field_names = resolution |> fields(nested, type) |> names_only()

      page_opts =
        if Enum.any?(field_names, &(&1 == :count)) do
          Keyword.put(page_opts, :count, true)
        else
          page_opts
        end

      {:ok, page_opts}
    end
  end

  defp validate_offset_opts(opts, :offset, %{max_page_size: max_page_size}) do
    limit =
      case opts |> Keyword.take([:limit]) |> Enum.into(%{}) do
        %{limit: limit} ->
          min(limit, max_page_size)

        _ ->
          max_page_size
      end

    {:ok, Keyword.put(opts, :limit, limit)}
  end

  defp validate_offset_opts(opts, _, _) do
    {:ok, opts}
  end

  defp validate_keyset_opts(opts, strategy, %{max_page_size: max_page_size})
       when strategy in [:keyset, :relay] do
    case opts |> Keyword.take([:first, :last, :after, :before]) |> Enum.into(%{}) do
      %{first: _first, last: _last} ->
        {:error,
         %Ash.Error.Query.InvalidQuery{
           message: "You can pass either `first` or `last`, not both",
           field: :first
         }}

      %{first: _first, before: _before} ->
        {:error,
         %Ash.Error.Query.InvalidQuery{
           message:
             "You can pass either `first` and `after` cursor, or `last` and `before` cursor",
           field: :first
         }}

      %{last: _last, after: _after} ->
        {:error,
         %Ash.Error.Query.InvalidQuery{
           message:
             "You can pass either `first` and `after` cursor, or `last` and `before` cursor",
           field: :last
         }}

      %{first: first} ->
        {:ok, opts |> Keyword.delete(:first) |> Keyword.put(:limit, min(first, max_page_size))}

      %{last: last, before: before} when not is_nil(before) ->
        {:ok, opts |> Keyword.delete(:last) |> Keyword.put(:limit, min(last, max_page_size))}

      %{last: _last} ->
        {:error,
         %Ash.Error.Query.InvalidQuery{
           message: "You can pass `last` only with `before` cursor",
           field: :last
         }}

      _ ->
        {:ok, Keyword.put(opts, :limit, max_page_size)}
    end
  end

  defp validate_keyset_opts(opts, _, _) do
    {:ok, opts}
  end

  defp get_result_fields(:keyset, true) do
    ["edges", "node"]
  end

  defp get_result_fields(:keyset, false) do
    ["results"]
  end

  defp get_result_fields(:offset, _) do
    ["results"]
  end

  defp get_result_fields(:relay, _) do
    ["edges", "node"]
  end

  defp get_result_fields(_pagination, _) do
    []
  end

  defp paginate_with_keyset(
         %Ash.Page.Keyset{
           results: results,
           more?: more,
           after: after_cursor,
           before: before_cursor,
           count: count
         },
         relay?
       ) do
    {start_cursor, end_cursor} =
      case results do
        [] ->
          {nil, nil}

        [first] ->
          {first.__metadata__.keyset, first.__metadata__.keyset}

        [first | rest] ->
          last = List.last(rest)
          {first.__metadata__.keyset, last.__metadata__.keyset}
      end

    {has_previous_page, has_next_page} =
      case {after_cursor, before_cursor} do
        {nil, nil} ->
          {false, more}

        {_, nil} ->
          {true, more}

        {nil, _} ->
          # https://github.com/ash-project/ash_graphql/pull/36#issuecomment-1243892511
          {more, not Enum.empty?(results)}
      end

    if relay? do
      {
        :ok,
        %{
          page_info: %{
            start_cursor: start_cursor,
            end_cursor: end_cursor,
            has_next_page: has_next_page,
            has_previous_page: has_previous_page
          },
          count: count,
          edges:
            Enum.map(results, fn result ->
              %{
                cursor: result.__metadata__.keyset,
                node: result
              }
            end)
        }
      }
    else
      {:ok, %{results: results, count: count, start_keyset: start_cursor, end_keyset: end_cursor}}
    end
  end

  defp paginate_with_offset(%Ash.Page.Offset{
         results: results,
         count: count,
         more?: more?,
         offset: offset,
         limit: limit
       }) do
    total_pages = get_total_pages(count, limit)
    has_next_page = more?
    has_previous_page = offset > 0
    page_number = get_current_page(%Ash.Page.Offset{limit: limit, offset: offset}, total_pages)
    last_page = total_pages

    {:ok,
     %{
       results: results,
       count: count,
       more?: more?,
       limit: limit,
       has_next_page: has_next_page,
       has_previous_page: has_previous_page,
       page_number: page_number,
       last_page: last_page
     }}
  end

  defp get_total_pages(count, _) when count in [0, nil], do: 1
  defp get_total_pages(_, nil), do: 1
  defp get_total_pages(total_count, limit), do: ceil(total_count / limit)

  defp get_current_page(%Ash.Page.Offset{limit: limit, offset: offset}, total),
    do: min(ceil(offset / limit) + 1, total)

  defp paginate(_resource, _gql_query, _action, %Ash.Page.Keyset{} = keyset, relay?) do
    paginate_with_keyset(keyset, relay?)
  end

  defp paginate(resource, query, action, %Ash.Page.Offset{} = offset, relay?) do
    # If a read action supports both offset and keyset, it will return an offset page by default
    # Check what strategy we're using and convert the page accordingly
    pagination_strategy = query_pagination_strategy(query, resource, action)

    if relay? or pagination_strategy == :keyset do
      offset
      |> offset_to_keyset()
      |> paginate_with_keyset(relay?)
    else
      paginate_with_offset(offset)
    end
  end

  defp paginate(resource, query, action, page, relay?) do
    case query_pagination_strategy(query, resource, action) do
      nil ->
        {:ok, page}

      :offset ->
        paginate(
          resource,
          query,
          action,
          %Ash.Page.Offset{results: page, count: Enum.count(page), more?: false},
          relay?
        )

      :keyset ->
        paginate(
          resource,
          query,
          action,
          %Ash.Page.Keyset{
            results: page,
            more?: false,
            after: nil,
            before: nil
          },
          relay?
        )

      _ ->
        {:ok, page}
    end
  end

  defp query_pagination_strategy(query, resource, action) when is_atom(action) do
    action = Ash.Resource.Info.action(resource, action)
    query_pagination_strategy(query, resource, action)
  end

  defp query_pagination_strategy(query, _resource, action) do
    AshGraphql.Resource.query_pagination_strategy(query, action)
  end

  defp offset_to_keyset(%Ash.Page.Offset{} = offset) do
    %Ash.Page.Keyset{
      results: offset.results,
      limit: offset.limit,
      more?: offset.more?,
      count: offset.count,
      after: nil,
      before: nil
    }
  end

  defp paginate_relationship(%Ash.Page.Keyset{} = keyset, strategy) do
    relay? = strategy == :relay
    paginate_with_keyset(keyset, relay?)
  end

  defp paginate_relationship(%Ash.Page.Offset{} = offset, strategy)
       when strategy in [:relay, :keyset] do
    # If a read action supports both offset and keyset, it will return an offset page by default,
    # so we might end up here even with relay or keyset strategy
    relay? = strategy == :relay

    offset
    |> offset_to_keyset()
    |> paginate_with_keyset(relay?)
  end

  defp paginate_relationship(%Ash.Page.Offset{} = offset, :offset) do
    paginate_with_offset(offset)
  end

  defp paginate_relationship(page, _) do
    {:ok, page}
  end

  def mutate(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def mutate(
        %{arguments: arguments, context: context} = resolution,
        {domain, resource,
         %{
           type: :create,
           name: mutation_name,
           action: action,
           upsert?: upsert?,
           upsert_identity: upsert_identity,
           args: args,
           modify_resolution: modify
         }, _relay_ids?}
      ) do
    case handle_mutation_arguments(resource, action, nil, arguments, args) do
      {:ok, input} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          source: :graphql,
          mutation_name: mutation_name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_mutation,
              mutation_name,
              metadata do
          opts = [
            actor: Map.get(context, :actor),
            action: action,
            authorize?: AshGraphql.Domain.Info.authorize?(domain),
            tenant: Map.get(context, :tenant),
            upsert?: upsert?
          ]

          opts =
            if upsert? && upsert_identity do
              Keyword.put(opts, :upsert_identity, upsert_identity)
            else
              opts
            end

          type_name = mutation_result_type(mutation_name)

          changeset =
            resource
            |> Ash.Changeset.new()
            |> Ash.Changeset.set_tenant(Map.get(context, :tenant))
            |> Ash.Changeset.set_context(get_context(context))
            |> Ash.Changeset.for_create(action, input,
              actor: Map.get(context, :actor),
              authorize?: AshGraphql.Domain.Info.authorize?(domain)
            )
            |> select_fields(resource, resolution, type_name, ["result"])
            |> load_fields(
              [
                domain: domain,
                tenant: Map.get(context, :tenant),
                authorize?: AshGraphql.Domain.Info.authorize?(domain),
                tracer: AshGraphql.Domain.Info.tracer(domain),
                actor: Map.get(context, :actor)
              ],
              resource,
              resolution,
              resolution.path,
              context,
              type_name,
              ["result"]
            )

          {result, modify_args} =
            changeset
            |> Ash.create(opts)
            |> case do
              {:ok, value} ->
                {{:ok, add_metadata(%{result: value, errors: []}, value, changeset.action)},
                 [changeset, {:ok, value}]}

              {:error, %{changeset: changeset} = error} ->
                {{:ok,
                  %{
                    result: nil,
                    errors: to_errors(changeset.errors, context, domain, resource, action)
                  }}, [changeset, {:error, error}]}
            end

          resolution
          |> Absinthe.Resolution.put_result(to_resolution(result, context, domain))
          |> add_root_errors(domain, resource, action, modify_args)
          |> modify_resolution(modify, modify_args)
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        if AshGraphql.Domain.Info.root_level_errors?(domain) do
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution({:error, error}, context, domain)
          )
        else
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution(
              {:ok, %{result: nil, errors: to_errors(error, context, domain, resource, action)}},
              context,
              domain
            )
          )
        end
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def mutate(
        %{arguments: arguments, context: context} = resolution,
        {domain, resource,
         %{
           name: mutation_name,
           type: :update,
           action: action,
           identity: identity,
           read_action: read_action,
           args: args,
           modify_resolution: modify
         }, relay_ids?}
      ) do
    read_action = read_action || Ash.Resource.Info.primary_action!(resource, :read).name

    case handle_mutation_arguments(resource, action, read_action, arguments, args) do
      {:ok, input, read_action_input} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          mutation: mutation_name,
          source: :graphql,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_mutation,
              mutation_name,
              metadata do
          filter = identity_filter(identity, resource, arguments, relay_ids?)

          case filter do
            {:ok, filter} ->
              query =
                resource
                |> Ash.Query.do_filter(filter)
                |> Ash.Query.set_tenant(Map.get(context, :tenant))
                |> Ash.Query.set_context(get_context(context))
                |> set_query_arguments(read_action, read_action_input)
                |> Ash.Query.limit(1)

              {result, modify_args} =
                query
                |> Ash.bulk_update(action, input,
                  return_errors?: true,
                  notify?: true,
                  strategy: [:atomic, :stream, :atomic_batches],
                  allow_stream_with: :full_read,
                  authorize_changeset_with: authorize_bulk_with(query.resource),
                  return_records?: true,
                  tenant: Map.get(context, :tenant),
                  context: get_context(context) || %{},
                  authorize?: AshGraphql.Domain.Info.authorize?(domain),
                  read_action: read_action,
                  domain: domain,
                  actor: Map.get(context, :actor),
                  select:
                    get_select(resource, resolution, mutation_result_type(mutation_name), [
                      "result"
                    ]),
                  load:
                    get_loads(
                      [
                        domain: domain,
                        tenant: Map.get(context, :tenant),
                        authorize?: AshGraphql.Domain.Info.authorize?(domain),
                        tracer: AshGraphql.Domain.Info.tracer(domain),
                        actor: Map.get(context, :actor)
                      ],
                      resource,
                      resolution,
                      resolution.path,
                      context,
                      mutation_result_type(mutation_name),
                      ["result"]
                    )
                )
                |> case do
                  %Ash.BulkResult{status: :success, records: [value]} ->
                    action = Ash.Resource.Info.action(resource, action)

                    {{:ok, add_metadata(%{result: value, errors: []}, value, action)},
                     [query, {:ok, value}]}

                  %Ash.BulkResult{status: :success, records: []} ->
                    {{:ok,
                      %{
                        result: nil,
                        errors:
                          to_errors(
                            [
                              Ash.Error.Query.NotFound.exception(
                                primary_key: Map.new(filter || []),
                                resource: resource
                              )
                            ],
                            context,
                            domain,
                            resource,
                            action
                          )
                      }},
                     [
                       query,
                       {:error,
                        Ash.Error.Query.NotFound.exception(
                          primary_key: Map.new(filter || []),
                          resource: resource
                        )}
                     ]}

                  %Ash.BulkResult{status: :error, errors: errors} ->
                    {{:ok,
                      %{result: nil, errors: to_errors(errors, context, domain, resource, action)}},
                     [query, {:error, errors}]}
                end

              resolution
              |> Absinthe.Resolution.put_result(to_resolution(result, context, domain))
              |> add_root_errors(domain, resource, action, modify_args)
              |> modify_resolution(modify, modify_args)

            {:error, error} ->
              Absinthe.Resolution.put_result(
                resolution,
                to_resolution({:error, error}, context, domain)
              )
          end
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        if AshGraphql.Domain.Info.root_level_errors?(domain) do
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution({:error, error}, context, domain)
          )
        else
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution(
              {:ok, %{result: nil, errors: to_errors(error, context, domain, resource, action)}},
              context,
              domain
            )
          )
        end
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  def mutate(
        %{arguments: arguments, context: context} = resolution,
        {domain, resource,
         %{
           name: mutation_name,
           type: :destroy,
           action: action,
           identity: identity,
           read_action: read_action,
           args: args,
           modify_resolution: modify
         }, relay_ids?}
      ) do
    read_action = read_action || Ash.Resource.Info.primary_action!(resource, :read).name

    case handle_mutation_arguments(resource, action, read_action, arguments, args) do
      {:ok, input, read_action_input} ->
        metadata = %{
          domain: domain,
          resource: resource,
          resource_short_name: Ash.Resource.Info.short_name(resource),
          actor: Map.get(context, :actor),
          tenant: Map.get(context, :tenant),
          action: action,
          source: :graphql,
          mutation: mutation_name,
          authorize?: AshGraphql.Domain.Info.authorize?(domain)
        }

        trace domain,
              resource,
              :gql_mutation,
              mutation_name,
              metadata do
          filter = identity_filter(identity, resource, arguments, relay_ids?)

          case filter do
            {:ok, filter} ->
              query =
                resource
                |> Ash.Query.do_filter(filter)
                |> Ash.Query.set_tenant(Map.get(context, :tenant))
                |> Ash.Query.set_context(get_context(context))
                |> set_query_arguments(read_action, read_action_input)
                |> Ash.Query.limit(1)
                |> pre_load_for_mutation(domain, resource, resolution, context, mutation_name)

              {result, modify_args} =
                query
                |> Ash.bulk_destroy(action, input,
                  return_errors?: true,
                  notify?: true,
                  authorize_changeset_with: authorize_bulk_with(query.resource),
                  strategy: [:atomic, :stream, :atomic_batches],
                  allow_stream_with: :full_read,
                  return_records?: true,
                  read_action: read_action,
                  tenant: Map.get(context, :tenant),
                  context: get_context(context) || %{},
                  authorize?: AshGraphql.Domain.Info.authorize?(domain),
                  actor: Map.get(context, :actor),
                  domain: domain,
                  select:
                    get_select(resource, resolution, mutation_result_type(mutation_name), [
                      "result"
                    ])
                )
                |> case do
                  %Ash.BulkResult{status: :success, records: [value]} ->
                    action = Ash.Resource.Info.action(resource, action)

                    {{:ok, add_metadata(%{result: value, errors: []}, value, action)},
                     [query, {:ok, value}]}

                  %Ash.BulkResult{status: :success, records: []} ->
                    {{:ok,
                      %{
                        result: nil,
                        errors:
                          to_errors(
                            [
                              Ash.Error.Query.NotFound.exception(
                                primary_key: Map.new(filter || []),
                                resource: resource
                              )
                            ],
                            context,
                            domain,
                            resource,
                            action
                          )
                      }},
                     [
                       query,
                       {:error,
                        Ash.Error.Query.NotFound.exception(
                          primary_key: Map.new(filter || []),
                          resource: resource
                        )}
                     ]}

                  %Ash.BulkResult{status: :error, errors: errors} ->
                    {{:ok,
                      %{result: nil, errors: to_errors(errors, context, domain, resource, action)}},
                     [query, {:error, errors}]}
                end

              resolution
              |> Absinthe.Resolution.put_result(to_resolution(result, context, domain))
              |> add_root_errors(domain, resource, action, modify_args)
              |> modify_resolution(modify, modify_args)

            {:error, error} ->
              Absinthe.Resolution.put_result(
                resolution,
                to_resolution({:error, error}, context, domain)
              )
          end
        end

      {:error, error} ->
        {:error, error}
    end
  rescue
    e ->
      if AshGraphql.Domain.Info.show_raised_errors?(domain) do
        error = Ash.Error.to_ash_error([e], __STACKTRACE__)

        if AshGraphql.Domain.Info.root_level_errors?(domain) do
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution({:error, error}, context, domain)
          )
        else
          Absinthe.Resolution.put_result(
            resolution,
            to_resolution(
              {:ok, %{result: nil, errors: to_errors(error, context, domain, resource, action)}},
              context,
              domain
            )
          )
        end
      else
        something_went_wrong(resolution, e, domain, __STACKTRACE__)
      end
  end

  if Application.compile_env(:ash_graphql, :authorize_update_destroy_with_error?) do
    def authorize_bulk_with(resource) do
      if Ash.DataLayer.data_layer_can?(resource, :expr_error) do
        :error
      else
        :filter
      end
    end
  else
    def authorize_bulk_with(_resource) do
      :filter
    end
  end

  defp log_exception(e, stacktrace) do
    uuid = Ash.UUID.generate()

    Logger.error(
      """
      #{uuid}: Exception raised while resolving query.

      #{String.slice(Exception.format(:error, e), 0, 2000)}

      #{Exception.format_stacktrace(stacktrace)}
      """,
      crash_reason: {e, stacktrace}
    )

    uuid
  end

  defp something_went_wrong(resolution, e, domain, stacktrace) do
    tracer = AshGraphql.Domain.Info.tracer(domain)

    Ash.Tracer.set_error(tracer, e)

    uuid = log_exception(e, stacktrace)

    Absinthe.Resolution.put_result(
      resolution,
      {:error,
       [
         %{
           message: "Something went wrong. Unique error id: `#{uuid}`",
           code: "something_went_wrong",
           vars: %{},
           fields: [],
           short_message: "Something went wrong."
         }
       ]}
    )
  end

  defp modify_resolution(resolution, nil, _), do: resolution

  defp modify_resolution(resolution, {m, f, a}, args) do
    apply(m, f, [resolution | args] ++ a)
  end

  def identity_filter(false, _resource, _arguments, _relay_ids?) do
    {:ok, nil}
  end

  def identity_filter(nil, resource, arguments, relay_ids?) do
    if relay_ids? or AshGraphql.Resource.Info.encode_primary_key?(resource) do
      case AshGraphql.Resource.decode_id(
             resource,
             Map.get(arguments, :id) || "",
             relay_ids?
           ) do
        {:ok, value} ->
          {:ok, value}

        {:error, error} ->
          {:error, error}
      end
    else
      resource
      |> Ash.Resource.Info.primary_key()
      |> Enum.reduce_while({:ok, nil}, fn key, {:ok, expr} ->
        value = Map.get(arguments, key)

        if value do
          if expr do
            {:cont, {:ok, Ash.Expr.expr(^expr and ^ref(key) == ^value)}}
          else
            {:cont, {:ok, Ash.Expr.expr(^ref(key) == ^value)}}
          end
        else
          {:halt, {:error, "Required key not present"}}
        end
      end)
    end
  end

  def identity_filter(identity, resource, arguments, _relay_ids?) do
    {:ok,
     resource
     |> Ash.Resource.Info.identities()
     |> Enum.find(&(&1.name == identity))
     |> Map.get(:keys)
     |> Enum.map(fn key ->
       {key, Map.get(arguments, key)}
     end)}
  end

  def massage_filter(_resource, nil), do: nil

  def massage_filter(resource, filter) when is_map(filter) do
    Enum.map(filter, fn {key, value} ->
      cond do
        rel = Ash.Resource.Info.relationship(resource, key) ->
          {key, massage_filter(rel.destination, value)}

        Ash.Resource.Info.calculation(resource, key) ->
          calc_input(key, value)

        true ->
          {key, value}
      end
    end)
  end

  def massage_filter(_resource, other), do: other

  defp calc_input(key, value) do
    case Map.fetch(value, :input) do
      {:ok, input} ->
        {key, {input, Map.delete(value, :input)}}

      :error ->
        {key, value}
    end
  end

  @doc false
  def load_fields(
        query_or_changeset,
        load_opts,
        resource,
        resolution,
        path,
        context,
        type_override,
        nested \\ []
      ) do
    load =
      get_loads(load_opts, resource, resolution, path, context, type_override, nested)

    case query_or_changeset do
      %Ash.Query{} = query ->
        Ash.Query.load(query, load)

      %Ash.Changeset{} = changeset ->
        Ash.Changeset.load(changeset, load)
    end
  end

  # Pre-load aggregates and calculations on the query before destruction
  # to ensure they are available in the returned record for GraphQL serialization
  defp pre_load_for_mutation(query, domain, resource, resolution, context, mutation_name) do
    load_opts = [
      domain: domain,
      tenant: Map.get(context, :tenant),
      authorize?: AshGraphql.Domain.Info.authorize?(domain),
      tracer: AshGraphql.Domain.Info.tracer(domain),
      actor: Map.get(context, :actor)
    ]

    load_fields(
      query,
      load_opts,
      resource,
      resolution,
      resolution.path,
      context,
      mutation_result_type(mutation_name),
      ["result"]
    )
  end

  @doc false
  def get_loads(
        load_opts,
        resource,
        resolution,
        path,
        context,
        type_override,
        nested \\ []
      ) do
    type_override = type_override || AshGraphql.Resource.Info.type(resource)

    {fields, path} = nested_fields_and_path(resolution, path, nested, type_override)

    resource_loads(fields, resource, resolution, load_opts, path, context)
  end

  defp nested_fields_and_path(resolution, path, nested, type \\ nil)

  defp nested_fields_and_path(resolution, path, [], type) do
    base = Enum.at(path, 0) || resolution

    selections =
      case base do
        %Absinthe.Resolution{} ->
          if type do
            Absinthe.Resolution.project(resolution, type)
          else
            Absinthe.Resolution.project(resolution)
          end

        %Absinthe.Blueprint.Document.Field{selections: selections} ->
          projection_type = type || base.schema_node.type

          {fields, _} =
            selections
            |> Absinthe.Resolution.Projector.project(
              Absinthe.Schema.lookup_type(resolution.schema, projection_type),
              path,
              %{},
              resolution
            )

          fields
      end

    {selections, path}
  end

  defp nested_fields_and_path(resolution, path, [nested | rest], _type) do
    base = Enum.at(path, 0) || resolution

    selections =
      case base do
        %Absinthe.Resolution{} ->
          Absinthe.Resolution.project(resolution)

        %Absinthe.Blueprint.Document.Field{selections: selections} ->
          {fields, _} =
            selections
            |> Absinthe.Resolution.Projector.project(
              Absinthe.Schema.lookup_type(resolution.schema, base.schema_node.type),
              path,
              %{},
              resolution
            )

          fields
      end

    selection = Enum.find(selections, &(&1.name == nested))

    if selection do
      nested_fields_and_path(resolution, [selection | path], rest)
    else
      {[], path}
    end
  end

  defp resource_loads(fields, resource, resolution, load_opts, path, context) do
    Enum.flat_map(fields, fn selection ->
      cond do
        aggregate = Ash.Resource.Info.aggregate(resource, selection.schema_node.identifier) ->
          [aggregate.name]

        calculation = Ash.Resource.Info.calculation(resource, selection.schema_node.identifier) ->
          arguments =
            selection.arguments
            |> Map.new(fn argument ->
              {argument.schema_node.identifier, argument.input_value.data}
            end)
            |> then(fn args ->
              if selection.alias do
                Map.put(args, :as, {:__ash_graphql_calculation__, selection.alias})
              else
                args
              end
            end)

          if Ash.Type.can_load?(calculation.type, calculation.constraints) do
            loads =
              type_loads(
                selection.selections,
                context,
                calculation.type,
                calculation.constraints,
                load_opts,
                resource,
                calculation.name,
                resolution,
                [selection | path],
                selection,
                AshGraphql.Resource.Info.type(resource)
              )

            case loads do
              [] ->
                [{calculation.name, arguments}]

              loads ->
                [{calculation.name, {arguments, loads}}]
            end
          else
            [{calculation.name, arguments}]
          end

        attribute = Ash.Resource.Info.attribute(resource, selection.schema_node.identifier) ->
          if Ash.Type.can_load?(attribute.type, attribute.constraints) do
            loads =
              type_loads(
                selection.selections,
                context,
                attribute.type,
                attribute.constraints,
                load_opts,
                resource,
                attribute.name,
                resolution,
                [selection | path],
                selection,
                AshGraphql.Resource.Info.type(resource)
              )

            case loads do
              [] ->
                if selection.alias do
                  {:ok, calc} =
                    Ash.Query.Calculation.new(
                      {:__ash_graphql_attribute__, selection.alias},
                      Ash.Resource.Calculation.LoadAttribute,
                      Keyword.put(load_opts, :attribute, attribute.name),
                      attribute.type,
                      attribute.constraints
                    )

                  [
                    calc
                  ]
                else
                  [attribute.name]
                end

              loads ->
                if selection.alias do
                  {:ok, calc} =
                    Ash.Query.Calculation.new(
                      {:__ash_graphql_attribute__, selection.alias},
                      Ash.Resource.Calculation.LoadAttribute,
                      Keyword.merge(load_opts, load: loads, attribute: attribute.name),
                      attribute.type,
                      attribute.constraints
                    )

                  [
                    calc
                  ]
                else
                  [{attribute.name, loads}]
                end
            end
          else
            [attribute.name]
          end

        relationship = Ash.Resource.Info.relationship(resource, selection.schema_node.identifier) ->
          read_action =
            case relationship.read_action do
              nil ->
                Ash.Resource.Info.primary_action!(relationship.destination, :read)

              read_action ->
                Ash.Resource.Info.action(relationship.destination, read_action)
            end

          args =
            Map.new(selection.arguments, fn argument ->
              {argument.schema_node.identifier, argument.input_value.data}
            end)

          related_query =
            relationship.destination
            |> Ash.Query.new()
            |> Ash.Query.set_tenant(Map.get(context, :tenant))
            |> Ash.Query.set_context(get_context(context))

          pagination_strategy =
            AshGraphql.Resource.relationship_pagination_strategy(
              resource,
              relationship.name,
              read_action
            )

          will_paginate? = pagination_strategy != nil
          relay? = pagination_strategy == :relay
          result_fields = get_result_fields(pagination_strategy, relay?)

          nested = Enum.map(Enum.reverse([selection | path]), & &1.name)

          related_query =
            if pagination_strategy && pagination_strategy != :none do
              case page_opts(
                     resolution,
                     relationship.destination,
                     read_action.pagination,
                     relay?,
                     args,
                     pagination_strategy,
                     nested
                   ) do
                {:ok, page_opts} ->
                  Ash.Query.page(related_query, page_opts)

                {:error, error} ->
                  Ash.Query.add_error(related_query, error)
              end
            else
              related_query
            end

          related_query =
            args
            |> apply_load_arguments(related_query, will_paginate?)
            |> set_query_arguments(read_action, args)
            |> select_fields(
              relationship.destination,
              resolution,
              nil,
              nested
            )
            |> load_fields(
              load_opts,
              relationship.destination,
              resolution,
              [
                selection | path
              ],
              context,
              nil,
              result_fields
            )

          if selection.alias do
            {type, constraints} =
              case relationship.cardinality do
                :many ->
                  {{:array, :struct}, items: [instance_of: relationship.destination]}

                :one ->
                  {:struct, instance_of: relationship.destination}
              end

            {:ok, calc} =
              Ash.Query.Calculation.new(
                {:__ash_graphql_relationship__, selection.alias},
                Ash.Resource.Calculation.LoadRelationship,
                Keyword.merge(load_opts, relationship: relationship.name, query: related_query),
                type,
                constraints
              )

            [
              calc
            ]
          else
            [{relationship.name, related_query}]
          end

        true ->
          []
      end
    end)
  end

  defp type_loads(
         selections,
         context,
         type,
         constraints,
         load_opts,
         resource,
         field_name,
         resolution,
         path,
         selection,
         parent_type_name,
         original_type \\ nil,
         already_expanded? \\ false
       )

  defp type_loads(
         selections,
         context,
         {:array, type},
         constraints,
         load_opts,
         resource,
         field_name,
         resolution,
         path,
         selection,
         parent_type_name,
         original_type,
         already_expanded?
       ) do
    type_loads(
      selections,
      context,
      type,
      constraints[:items] || [],
      load_opts,
      resource,
      field_name,
      resolution,
      path,
      selection,
      parent_type_name,
      original_type,
      already_expanded?
    )
  end

  defp type_loads(
         selections,
         context,
         type,
         constraints,
         load_opts,
         resource,
         field_name,
         resolution,
         path,
         selection,
         parent_type_name,
         original_type,
         already_expanded?
       ) do
    cond do
      Ash.Type.NewType.new_type?(type) ->
        subtype_constraints = Ash.Type.NewType.constraints(type, constraints)
        subtype_of = Ash.Type.NewType.subtype_of(type)

        type_loads(
          selections,
          context,
          subtype_of,
          subtype_constraints,
          load_opts,
          resource,
          field_name,
          resolution,
          path,
          selection,
          parent_type_name,
          {type, constraints},
          already_expanded?
        )

      AshGraphql.Resource.embedded?(type) || Ash.Resource.Info.resource?(type) ||
          (type in [Ash.Type.Struct, :struct] && constraints[:instance_of] &&
             (AshGraphql.Resource.embedded?(constraints[:instance_of]) ||
                Ash.Resource.Info.resource?(constraints[:instance_of]))) ->
        type =
          if type in [:struct, Ash.Type.Struct] do
            constraints[:instance_of]
          else
            type
          end

        fields =
          if already_expanded? do
            selections
          else
            value_type =
              Absinthe.Schema.lookup_type(resolution.schema, selection.schema_node.type)

            {fields, _} =
              Absinthe.Resolution.Projector.project(
                selections,
                value_type,
                path,
                %{},
                resolution
              )

            fields
          end

        resource_loads(fields, type, resolution, load_opts, path, context)

      type == Ash.Type.Union ->
        {global_selections, fragments} =
          Enum.split_with(selections, fn
            %Absinthe.Blueprint.Document.Field{} ->
              true

            _ ->
              false
          end)

        loads =
          case global_selections do
            [] ->
              []

            global_selections ->
              first_type_config =
                constraints[:types]
                |> Enum.at(0)
                |> elem(1)

              first_type = first_type_config[:type]
              first_constraints = first_type_config[:constraints]

              type_loads(
                global_selections,
                context,
                first_type,
                first_constraints,
                load_opts,
                resource,
                field_name,
                resolution,
                path,
                selection,
                parent_type_name,
                original_type
              )
          end

        {graphql_unnested_unions, configured_type_name} =
          case original_type do
            {type, constraints} ->
              configured_type_name =
                if function_exported?(type, :graphql_type, 1) do
                  type.graphql_type(constraints)
                end

              unnested_unions =
                if function_exported?(type, :graphql_unnested_unions, 1) do
                  type.graphql_unnested_unions(constraints)
                else
                  []
                end

              {unnested_unions, configured_type_name}

            _ ->
              {[], nil}
          end

        constraints[:types]
        |> Enum.filter(fn {_, config} ->
          Ash.Type.can_load?(config[:type], config[:constraints])
        end)
        |> Enum.reduce(loads, fn {type_name, config}, acc ->
          {gql_type_name, nested?} =
            if type_name in graphql_unnested_unions do
              {AshGraphql.Resource.field_type(
                 config[:type],
                 %Ash.Resource.Attribute{
                   name: configured_type_name,
                   type: config[:type],
                   constraints: config[:constraints]
                 },
                 resource
               ), false}
            else
              {AshGraphql.Resource.nested_union_type_name(
                 %{name: configured_type_name || "#{parent_type_name}_#{field_name}"},
                 type_name,
                 true
               ), true}
            end

          gql_type = Absinthe.Schema.lookup_type(resolution.schema, gql_type_name)

          if !gql_type do
            raise Ash.Error.Framework.AssumptionFailed,
              message: "Could not find a corresponding graphql type for #{inspect(gql_type_name)}"
          end

          if nested? do
            {fields, _} =
              Absinthe.Resolution.Projector.project(
                fragments,
                gql_type,
                path,
                %{},
                resolution
              )

            if selection = Enum.find(fields, &(&1.schema_node.identifier == :value)) do
              Keyword.put(
                acc,
                type_name,
                type_loads(
                  selection.selections,
                  context,
                  config[:type],
                  config[:constraints],
                  load_opts,
                  resource,
                  gql_type_name,
                  resolution,
                  [selection | path],
                  selection,
                  gql_type_name,
                  original_type
                )
              )
            else
              acc
            end
          else
            {fields, _} =
              Absinthe.Resolution.Projector.project(
                fragments,
                gql_type,
                path,
                %{},
                resolution
              )

            Keyword.put(
              acc,
              type_name,
              type_loads(
                fields,
                context,
                config[:type],
                config[:constraints],
                load_opts,
                resource,
                gql_type_name,
                resolution,
                path,
                selection,
                gql_type_name,
                original_type,
                true
              )
            )
          end
        end)

      true ->
        []
    end
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp mutation_result_type(mutation_name) do
    String.to_atom("#{mutation_name}_result")
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp subscription_result_type(subscription_name) do
    String.to_atom("#{subscription_name}_result")
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp page_type(resource, strategy, relay?) do
    type = AshGraphql.Resource.Info.type(resource)

    cond do
      relay? ->
        String.to_atom("#{type}_connection")

      strategy == :keyset ->
        String.to_atom("keyset_page_of_#{type}")

      strategy == :offset ->
        String.to_atom("page_of_#{type}")
    end
  end

  @doc false
  def select_fields(
        query_or_changeset,
        resource,
        resolution,
        type_override,
        nested \\ []
      ) do
    subfields = get_select(resource, resolution, type_override, nested)

    case query_or_changeset do
      %Ash.Query{} = query ->
        query |> Ash.Query.select(subfields)

      %Ash.Changeset{} = changeset ->
        changeset |> Ash.Changeset.select(subfields)
    end
  end

  defp get_select(resource, resolution, type_override, nested) do
    type = type_override || AshGraphql.Resource.Info.type(resource)

    resolution
    |> fields(nested, type)
    |> names_only()
    |> Enum.map(&field_or_relationship(resource, &1))
    |> Enum.filter(& &1)
    |> Enum.map(& &1.name)
  end

  defp field_or_relationship(resource, identifier) do
    case Ash.Resource.Info.attribute(resource, identifier) do
      nil ->
        case Ash.Resource.Info.relationship(resource, identifier) do
          nil ->
            nil

          rel ->
            Ash.Resource.Info.attribute(resource, rel.source_attribute)
        end

      attr ->
        attr
    end
  end

  defp fields(%Absinthe.Resolution{} = resolution, [], type) do
    resolution
    |> Absinthe.Resolution.project(type)
  end

  defp fields(%Absinthe.Resolution{} = resolution, names, _type) do
    # Here we don't pass the type to project because the Enum.reduce below already
    # takes care of projecting the nested fields using the correct type

    project =
      resolution
      |> Absinthe.Resolution.project()

    cache = resolution.fields_cache

    Enum.reduce(names, {project, cache}, fn name, {fields, cache} ->
      case fields |> Enum.find(&(&1.name == name)) do
        nil ->
          {fields, cache}

        selection ->
          type = Absinthe.Schema.lookup_type(resolution.schema, selection.schema_node.type)

          selection
          |> Map.get(:selections)
          |> Absinthe.Resolution.Projector.project(
            type,
            [selection | resolution.path],
            cache,
            resolution
          )
      end
    end)
    |> elem(0)
  end

  defp names_only(fields) do
    Enum.map(fields, & &1.schema_node.identifier)
  end

  @doc false
  def set_query_arguments(query, action, arg_values) do
    action =
      if is_atom(action) do
        Ash.Resource.Info.action(query.resource, action)
      else
        action
      end

    action.arguments
    |> Enum.filter(& &1.public?)
    |> Enum.reduce(query, fn argument, query ->
      case Map.fetch(arg_values, argument.name) do
        {:ok, value} ->
          Ash.Query.set_argument(query, argument.name, value)

        _ ->
          query
      end
    end)
  end

  defp add_root_errors(resolution, domain, resource, action, {:error, error_or_errors}) do
    do_root_errors(domain, resource, action, resolution, error_or_errors)
  end

  defp add_root_errors(resolution, domain, resource, action, [_, {:error, error_or_errors}]) do
    do_root_errors(domain, resource, action, resolution, error_or_errors)
  end

  defp add_root_errors(resolution, domain, resource, action, [_, {:ok, %{errors: errors}}])
       when errors not in [nil, []] do
    do_root_errors(domain, resource, action, resolution, errors, false)
  end

  defp add_root_errors(resolution, domain, resource, action, {:ok, %{errors: errors}})
       when errors not in [nil, []] do
    do_root_errors(domain, resource, action, resolution, errors, false)
  end

  defp add_root_errors(resolution, _domain, _resource, _action, _other_thing) do
    resolution
  end

  defp do_root_errors(domain, resource, action, resolution, error_or_errors, to_errors? \\ true) do
    if AshGraphql.Domain.Info.root_level_errors?(domain) do
      Map.update!(resolution, :errors, fn current_errors ->
        if to_errors? do
          Enum.concat(
            current_errors || [],
            List.wrap(to_errors(error_or_errors, resolution.context, domain, resource, action))
          )
        else
          Enum.concat(current_errors || [], List.wrap(error_or_errors))
        end
      end)
    else
      resolution
    end
  end

  defp add_read_metadata({:error, error}, _, _) do
    {:error, error}
  end

  defp add_read_metadata({:ok, result}, query, action) do
    {:ok, add_read_metadata(result, query, action)}
  end

  defp add_read_metadata(nil, _, _), do: nil

  defp add_read_metadata(result, query, action) when is_list(result) do
    show_metadata = query.show_metadata || Enum.map(Map.get(action, :metadata, []), & &1.name)

    Enum.map(result, fn record ->
      do_add_read_metadata(record, show_metadata)
    end)
  end

  defp add_read_metadata(result, query, action) do
    show_metadata = query.show_metadata || Enum.map(Map.get(action, :metadata, []), & &1.name)

    do_add_read_metadata(result, show_metadata)
  end

  defp do_add_read_metadata(record, show_metadata) do
    Enum.reduce(show_metadata, record, fn key, record ->
      Map.put(record, key, Map.get(record.__metadata__ || %{}, key))
    end)
  end

  defp add_metadata(result, action_result, action) do
    metadata = Map.get(action, :metadata, [])

    if Enum.empty?(metadata) do
      result
    else
      metadata =
        Map.new(action.metadata, fn metadata ->
          {metadata.name, Map.get(action_result.__metadata__ || %{}, metadata.name)}
        end)

      Map.put(result, :metadata, metadata)
    end
  end

  @doc false
  def unwrap_errors([]), do: []

  def unwrap_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(fn
      %class{errors: errors} when class in [Ash.Error.Invalid, Ash.Error.Forbidden] ->
        unwrap_errors(List.wrap(errors))

      errors ->
        List.wrap(errors)
    end)
  end

  defp to_errors(errors, context, domain, resource, action) do
    AshGraphql.Errors.to_errors(errors, context, domain, resource, action)
  end

  def resolve_calculation(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_calculation(
        %Absinthe.Resolution{
          source: parent,
          context: context
        } = resolution,
        {domain, resource, calculation}
      ) do
    domain = domain || context[:domain]

    result =
      if resolution.definition.alias do
        Map.get(parent.calculations, {:__ash_graphql_calculation__, resolution.definition.alias})
      else
        Map.get(parent, calculation.name)
      end

    case result do
      %struct{} when struct == Ash.ForbiddenField ->
        Absinthe.Resolution.put_result(
          resolution,
          to_resolution(
            {:error,
             Ash.Error.Forbidden.ForbiddenField.exception(
               resource: resource,
               field: resolution.definition.name
             )},
            context,
            domain
          )
        )

      result ->
        unwrapped_type =
          unwrap_type(calculation.type)

        result =
          if Ash.Type.NewType.new_type?(unwrapped_type) &&
               Ash.Type.NewType.subtype_of(unwrapped_type) == Ash.Type.Union &&
               function_exported?(unwrapped_type, :graphql_unnested_unions, 1) do
            unnested_types = unwrapped_type.graphql_unnested_unions(calculation.constraints)

            resolve_union_result(
              result,
              {calculation.name, calculation.type, calculation, resource, unnested_types, domain}
            )
          else
            result
          end

        Absinthe.Resolution.put_result(resolution, to_resolution({:ok, result}, context, domain))
    end
  end

  defp unwrap_type({:array, type}),
    do: unwrap_type(type)

  defp unwrap_type(other), do: other

  def resolve_assoc_one(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_assoc_one(
        %{source: parent} = resolution,
        {_domain, relationship}
      ) do
    value =
      if resolution.definition.alias do
        Map.get(parent.calculations, {:__ash_graphql_relationship__, resolution.definition.alias})
      else
        Map.get(parent, relationship.name)
      end

    Absinthe.Resolution.put_result(resolution, {:ok, value})
  end

  def resolve_assoc_many(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_assoc_many(
        %{source: parent} = resolution,
        {_domain, relationship, pagination_strategy}
      ) do
    page =
      if resolution.definition.alias do
        Map.get(parent.calculations, {:__ash_graphql_relationship__, resolution.definition.alias})
      else
        Map.get(parent, relationship.name)
      end

    result = paginate_relationship(page, pagination_strategy)

    Absinthe.Resolution.put_result(resolution, result)
  end

  def resolve_id(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_id(
        %{source: parent} = resolution,
        {_resource, _field, relay_ids?}
      ) do
    Absinthe.Resolution.put_result(
      resolution,
      {:ok, AshGraphql.Resource.encode_id(parent, relay_ids?)}
    )
  end

  def resolve_union(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_union(
        %{source: parent, context: context} = resolution,
        {name, _field_type, _field, resource, _unnested_types, domain} = data
      ) do
    domain = domain || context[:domain]

    value =
      if resolution.definition.alias do
        Map.get(parent.calculations, {:__ash_graphql_attribute__, resolution.definition.alias})
      else
        Map.get(parent, name)
      end

    case value do
      %struct{} when struct == Ash.ForbiddenField ->
        Absinthe.Resolution.put_result(
          resolution,
          to_resolution(
            {:error,
             Ash.Error.Forbidden.ForbiddenField.exception(
               resource: resource,
               field: resolution.definition.name
             )},
            context,
            domain
          )
        )

      value ->
        result = resolve_union_result(value, data)

        Absinthe.Resolution.put_result(resolution, {:ok, result})
    end
  end

  def resolve_attribute(
        %{source: %resource{} = parent, context: context} = resolution,
        {name, type, constraints, domain}
      ) do
    domain = domain || context[:domain]

    value =
      if resolution.definition.alias && Ash.Type.can_load?(type, constraints) do
        Map.get(parent.calculations, {:__ash_graphql_attribute__, resolution.definition.alias})
      else
        Map.get(parent, name)
      end

    case value do
      %struct{} when struct == Ash.ForbiddenField ->
        Absinthe.Resolution.put_result(
          resolution,
          to_resolution(
            {:error,
             Ash.Error.Forbidden.ForbiddenField.exception(
               resource: resource,
               field: resolution.definition.name
             )},
            context,
            domain
          )
        )

      value ->
        Absinthe.Resolution.put_result(resolution, {:ok, value})
    end
  end

  def resolve_attribute(
        %{source: nil} = resolution,
        _
      ) do
    Absinthe.Resolution.put_result(resolution, {:ok, nil})
  end

  def resolve_attribute(
        %{source: parent} = resolution,
        {name, type, constraints, _domain}
      )
      when is_map(parent) do
    value =
      if resolution.definition.alias && Ash.Type.can_load?(type, constraints) do
        Map.get(parent.calculations, {:__ash_graphql_attribute__, resolution.definition.alias})
      else
        Map.get(parent, name)
      end

    Absinthe.Resolution.put_result(resolution, {:ok, value})
  end

  def resolve_attribute(
        %{source: source},
        _
      ) do
    raise "unknown source #{inspect(source)}"
  end

  defp resolve_union_result(
         value,
         {name, {:array, field_type}, field, resource, unnested_types, domain}
       ) do
    if value do
      Enum.map(
        value,
        &resolve_union_result(
          &1,
          {name, field_type, %{field | type: field_type, constraints: field.constraints[:items]},
           resource, unnested_types, domain}
        )
      )
    end
  end

  defp resolve_union_result(
         value,
         {_name, field_type, field, resource, unnested_types, _domain}
       ) do
    case value do
      %Ash.Union{type: type, value: value} = union ->
        constraints = Ash.Type.NewType.constraints(field_type, field.constraints)

        if type in unnested_types and not is_nil(value) do
          type =
            AshGraphql.Resource.field_type(
              constraints[:types][type][:type],
              %{field | constraints: constraints[:types][type][:constraints]},
              resource
            )

          Map.put(value, :__union_type__, type)
        else
          union
        end

      other ->
        other
    end
  end

  def resolve_keyset(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_keyset(
        %{source: parent} = resolution,
        _field
      ) do
    Absinthe.Resolution.put_result(resolution, {:ok, Map.get(parent.__metadata__, :keyset)})
  end

  def resolve_composite_id(%Absinthe.Resolution{state: :resolved} = resolution, _),
    do: resolution

  def resolve_composite_id(
        %{source: parent} = resolution,
        {_resource, _fields, relay_ids?}
      ) do
    Absinthe.Resolution.put_result(
      resolution,
      {:ok, AshGraphql.Resource.encode_id(parent, relay_ids?)}
    )
  end

  def query_complexity(
        %{limit: limit},
        child_complexity,
        _
      ) do
    if child_complexity == 0 do
      1
    else
      limit * child_complexity
    end
  end

  def query_complexity(
        _,
        child_complexity,
        _
      ) do
    child_complexity + 1
  end

  def resolve_node(
        %{arguments: %{id: id}} = resolution,
        {type_to_domain_and_resource_map, all_domains}
      ) do
    case AshGraphql.Resource.decode_relay_id(id) do
      {:ok, %{type: type, id: primary_key}} ->
        {domain, resource} = Map.fetch!(type_to_domain_and_resource_map, type)
        # We can be sure this returns something since we check this at compile time
        query = AshGraphql.Resource.primary_key_get_query(resource, all_domains)

        # We pass relay_ids? as false since we pass the already decoded primary key
        put_in(resolution.arguments.id, primary_key)
        |> resolve({domain, resource, query, false})

      {:error, _reason} = error ->
        Absinthe.Resolution.put_result(resolution, error)
    end
  end

  def resolve_node_type(%resource{}, _) do
    AshGraphql.Resource.Info.type(resource)
  end

  defp apply_load_arguments(arguments, query, will_paginate?) do
    Enum.reduce(arguments, query, fn
      {:limit, limit}, query when not will_paginate? ->
        Ash.Query.limit(query, limit)

      {:offset, offset}, query when not will_paginate? ->
        Ash.Query.offset(query, offset)

      {:filter, value}, query ->
        Ash.Query.filter_input(query, massage_filter(query.resource, value))

      {:sort, value}, query ->
        keyword_sort =
          Enum.map(value, fn %{order: order, field: field} = input ->
            case Ash.Resource.Info.calculation(query.resource, field) do
              %{arguments: [_ | _]} ->
                input_name = String.to_existing_atom("#{field}_input")

                {field, {input[input_name] || %{}, order}}

              _ ->
                {field, order}
            end
          end)

        Ash.Query.sort_input(query, keyword_sort)

      _, query ->
        query
    end)
  end

  @doc false
  def to_resolution({:ok, value}, _context, _domain), do: {:ok, value}

  def to_resolution({:error, error}, context, domain) do
    {:error,
     error
     |> unwrap_errors()
     |> Enum.map(fn error ->
       if AshGraphql.Error.impl_for(error) do
         error = AshGraphql.Error.to_error(error)

         case AshGraphql.Domain.Info.error_handler(domain) do
           nil ->
             error

           {m, f, a} ->
             apply(m, f, [error, context | a])
         end
       else
         uuid = Ash.UUID.generate()

         stacktrace =
           case error do
             %{stacktrace: %{stacktrace: v}} ->
               v

             _ ->
               nil
           end

         Logger.warning(
           "`#{uuid}`: AshGraphql.Error not implemented for error:\n\n#{Exception.format(:error, error, stacktrace)}"
         )

         if AshGraphql.Domain.Info.show_raised_errors?(domain) do
           %{
             message: """
             Raised error: #{uuid}

             #{Exception.format(:error, error, stacktrace)}"
             """
           }
         else
           %{
             message: "Something went wrong. Unique error id: `#{uuid}`"
           }
         end
       end
     end)}
  end
end
