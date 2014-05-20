# stormbolt API endpoints

@include = ->

    agent = @settings.agent

    @get '/clients': ->
        @send agent.clients.list()

    @get '/clients/:id': ->
        match = agent.clients.get @params.id
        if match?
            @send match
        else
            @send 404
