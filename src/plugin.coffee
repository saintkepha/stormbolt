# stormbolt API endpoints

@include = ->

    agent = @settings.agent

    @get '/clients': ->
        @send agent.clients()

    @get '/clients/:id': ->
        match = agent.clients @params.id
        if match?
            @send match
        else
            @send 404
