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

    # proxy operation for stormflash requests
    @all '/proxy/:id/*': ->
        bolt = agent.clients.entries[@params.id]
        if bolt? and bolt.relay?
            @req.target = 8000
            @req.url = @params[0]
            # pipes @req stream via bolt back up to @res stream
            bolt.relay @req, @res
        else
            @send 404
