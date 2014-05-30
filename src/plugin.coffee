# stormbolt API endpoints

@include = ->

    agent = @settings.agent

    @head '/clients': ->
        checksum = agent.clients.checksum()
        agent.log "checksum: #{checksum}"
        @res.set 'Content-MD5', checksum
        @send ''

    @get '/clients': ->
        @send agent.clients.list()

    @get '/clients/:id': ->
        match = agent.clients.get @params.id
        if match?
            @send match
        else
            @send 404

    # proxy operation for stormflash requests
    @all '/proxy/:id@:port/*': ->
        bolt = agent.clients.entries[@params.id]
        port = (Number) @params.port
        if bolt? and bolt.relay? and port in bolt.capability
            @req.target = port
            @req.url = @params[0]
            @req.data = @body
            # pipes @req stream via bolt back up to @res stream
            bolt.relay @req, @res
        else
            @send 404
