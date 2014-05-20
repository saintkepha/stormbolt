
#Workaround - fix it later, Avoids DEPTH_ZERO_SELF_SIGNED_CERT error for self-signed certs
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

StormAgent = require 'stormagent'

StormData = StormAgent.StormData

# XXX - for now, only representing the server-side... will refactor for client-side later
class BoltStream extends StormData

    MuxDemux = require('mux-demux')

    constructor: (@id, @stream) ->
        @stream.pipe(@mux = MuxDemux()).pipe(@stream)

        @cstream = @mux.createReadStream 'capability'
        @cstream.on 'data', (capa) =>
            @log "received capability info from client:", capa
            @capability = capa.split(',') ? []
            @emit 'capability', capa

        @bstream = @mux.createStream 'beacon', { allowHalfOpen:true }
        @bstream.on 'data', (beacon) =>
            @log "received beacon from client: #{cname}"
            @bstream.write "beacon:reply"

            @emit 'beacon', beacon
            @validity = @config.beaconValidity # reset

        @mux.on 'error', (err) =>
            @log "issue with bolt mux channel...", err
            @stream.destroy()
            @emit 'error', err

        @stream.on 'close', =>
            @log "bolt stream closed for #{@id} to #{@stream.remoteAddress}"
            @emit 'closed'

        @stream.on 'error', (err) =>
            @log "issue with underlying bolt stream...", err
            @mux.destroy()
            @emit 'error', err

        super @id,
            cname:  @id
            remote: @stream.remoteAddress

    relay: (request, callback) ->
        @log "relay - forwarding request to #{@id} at #{@stream.remoteAddress}"
        try
            relay = @mux.createStream("relay:#{request.target}", {allowHalfOpen:true})
            relay.write JSON.stringify
                method:  request.method,
                url:     request.url,
                headers: request.headers

            request.setEncoding 'utf8'
            request.pipe relay
            data = ''
            relay.on 'data', (chunk) ->
                data += chunk
                callback chunk
            relay.on 'end', ->
                callback data, true
            relay.on 'error', (err) ->
                @log "error during relay multiplexing boltstream...", err
                callback err
        catch err
            @log "error duing relaying request to boltstream", err
            callback err

    destroy: ->
        try
            @mux.close()
            @stream.destroy()
        catch err
            @log "unable to properly terminate bolt stream: #{bolt.id}", err

StormRegistry = StormAgent.StormRegistry

class BoltRegistry extends StormRegistry

    constructor: (filename) ->
        @on 'removed', (bolt) ->
            bolt.destroy() if bolt?

        super filename

    get: (key) ->
        entry = super key
        cname: key
        ports: entry.capability
        address: entry.data.remote
        validity: entry.validity

#-----------------------------------------------------------------

class StormBolt extends StormAgent

    validate = require('json-schema').validate
    tls = require("tls")
    fs = require("fs")
    http = require("http")
    url = require('url')
    MuxDemux = require('mux-demux')
    async = require('async')
    extend = require('util')._extend

    schema =
        name: "storm"
        type: "object"
        additionalProperties: true
        properties:
            cert:           { type: "any", required: true }
            key:            { type: "any", required: true }
            ca:             { type: "any", required: true }
            uplinks:        { type: "array" }
            uplinkStrategy: { type: "string" }
            allowRelay:     { type: "boolean" }
            relayPort:      { type: "integer" }
            allowedPorts:   { type: "array" }
            listenPort:     { type: "integer" }
            beaconInterval: { type: "integer" }
            beaconRetry:    { type: "integer" }

    constructor: (config) ->
        super config

        # key routine to import itself into agent base
        @import module

        @repeatInterval = 5 # in seconds
        @clients = new BoltRegistry

    status: ->
        state = super
        state.uplink = @uplink ? null
        state.clients = @clients.list()
        state

    run: (config) ->

        if config?
            @log 'run called with:', config
            res = validate config, schema
            @log 'run - validation of runtime config:', res
            @config = extend(@config, config) if res.valid

        # start the agent web api instance...
        super config

        try
            @log 'run - validating security credentials...'
            unless @config.cert instanceof Buffer
                @config.cert = fs.readFileSync "#{@config.cert}",'utf8'

            unless @config.key instanceof Buffer
                @config.key =  fs.readFileSync "#{@config.key}",'utf8'

            unless @config.ca instanceof Buffer
                ca = []
                chain = fs.readFileSync "#{@config.ca}", 'utf8'
                chain = chain.split "\n"
                cacert = []
                for line in chain when line.length isnt 0
                    cacert.push line
                    if line.match /-END CERTIFICATE-/
                        ca.push cacert.join "\n"
                        cacert = []
                @config.ca = ca
        catch err
            @log "run - missing proper security credentials, attempting to self-configure..."
            @activate null, (err, storm) =>
                unless err
                    @on "error", (err) =>
                        @log "run - bolt fizzled... should do something smart here"
                    @run storm.bolt
            return

        # check for bolt server config
        if @config.listenPort? and @config.listenPort > 0
            server = @listen @config.listenPort,
                key: @config.key
                cert: @config.cert
                ca: @config.ca
                requestCert: true
                rejectUnauthorized: true
               , (bolt) =>
                bolt.validity ?= @config.beaconValidity if @config.beaconValidity
                @clients.add bolt.id, bolt
                bolt.on 'beacon', (beacon) =>
                    ### not sure if we need this logic...
                    entry = @clients.get bolt.id
                    entry.validity = @config.beaconValidity
                    @clients.update bolt.id, entry
                    ###
                bolt.on 'close', (err) =>
                    @clients.remove bolt.id
                bolt.on 'error', (err) =>
                    @clients.remove bolt.id

            server.on 'error', (err) =>
                @log "fatal issue with bolt server: "+err
                @clients.running = false
                @emit 'server.error', err

            # start client connection expiry checker
            @clients.expires @config.repeatdelay


        # check for client uplink to bolt server
        if @config.uplinks? and @config.uplinks.length > 0

            [ i, retries ] = [ 0, 0 ]

            connected = false
            @on 'client.connection', (stream) =>
                connected = true
                retries = 0
            @on 'client.disconnect', (stream) =>
                connected = false

            async.forever(
                (next) =>
                    next new Error "retry max exceeded, unable to establish bolt server connection" if retries > 30
                    unless connected
                        uplink = @config.uplinks[i++]
                        [ host, port ] = uplink.split(':')
                        @connect host,port,
                            key: @config.key
                            cert: @config.cert
                            ca: @config.ca
                            requestCert: true
                        i = 0 unless i < @config.uplinks.length
                    setTimeout(next, 5000)
                (err) =>
                    @emit 'error', err if err?
            )
        # check for running the relay proxy
        @proxy(@config.relayPort) if @config.allowRelay

    proxy: (port) ->
        unless port? and port > 0
            @log "need to pass in valid port for performing relay"
            return

        @log 'starting the relay on port ' + port
        # after initial data, invoke HTTP server listener on port
        acceptor = http.createServer().listen(port)
        acceptor.on "request", (request,response) =>
            target = request.headers['stormbolt-target']
            [ cname, port ] = target.split(':') if target

            entry = @clients.get cname
            unless entry
                error = "no such stormfbolt-target [#{target}] currently connected!"
                @log "error:", error
                response.writeHead(404, {
                    'Content-Length': error.length,
                    'Content-Type': 'application/json',
                    'Connection': 'close' })
                response.end(error,"utf8")
                return

            @log "[proxy] forwarding request to " + cname + " at " + entry.stream.remoteAddress
            firstreply = false
            request.target = port
            entry.relay request, (res) =>
                unless res instanceof Error and firstreply
                    try
                        reply = JSON.parse res
                        response.writeHead(reply.statusCode, reply.headers)
                        relay.pipe(response)
                    catch err
                        @log "invalid relay response!"
                        relay.end()

    # Method to start bolt server
    listen: (port, options, callback) ->
        @log "server port:" + port
        #@log "options: " + @inspect options
        server = tls.createServer options, (stream) =>
            try
                @log "TLS connection established with VCG client from: " + stream.remoteAddress
                @log 'Debugging null certs issue : server authorizationError: ' + stream.authorizationError
                certObj = stream.getPeerCertificate()
                cname = certObj.subject.CN

                @log "server connected from #{cname}: " + stream.authorized ? 'unauthorized'
                callback new BoltStream cname, stream if callback?

            catch error
                @log 'unable to retrieve peer certificate and authorize connection!', error
                stream.end()

        server.on 'error', (err) =>
            @log 'server connection error :' + err.message
            try
                message = String(err.message)
                if (message.indexOf ('ECONNRESET')) >= 0
                    @log 'throw error: ' + 'ECONNRESET'
                    throw new Error err
            catch e
                @log 'error e' + e
                #process.exit(1)

        server.listen port
        return server

    #Method to start bolt client
    connect: (host, port, options) ->
        tls.SLAB_BUFFER_SIZE = 100 * 1024
        # try to connect to the server
        @log "making connection to bolt server at: "+host+':'+port
        #@log @inspect options
        calledReconnectOnce = false
        stream = tls.connect(port, host, options, =>
            @uplink =
                host: host
                port: port
                options: options
            if stream.authorized
                @log "Successfully connected to bolt server"
#                @emit 'client.connection', stream
            else
                @log "Failed to authorize TLS connection. Could not connect to bolt server (ignored for now)"

            @emit 'client.connection', stream
            stream.setKeepAlive(true, 60 * 1000) #Send keep-alive every 60 seconds
            stream.setEncoding 'utf8'
            stream.pipe(mx=MuxDemux()).pipe(stream)

            forwardingPorts = @config.allowedPorts

            mx.on "connection", (_stream) =>
                [ action, target ] = _stream.meta.split(':')
                @log "Client: action #{action}  target #{target}"

                _stream.on 'error', (err) =>
                    @log "Client: mux stream for #{_stream.meta} has error: "+err

                switch action
                    when 'capability'
                        @log 'sending capability information...'
                        _stream.write forwardingPorts.join(',')
                        _stream.end()

                    when 'beacon'
                        [ bsent, breply ] = [ 0 , 0 ]
                        _stream.on 'data', (data) =>
                            breply++
                            @log "received beacon reply: #{data}"

                        @log 'sending beacons...'
                        async.whilst(
                            () => # test to make sure deviation between sent and received does not exceed beaconRetry
                                bsent - breply < @config.beaconRetry
                            (repeat) => # send some beacons
                                @log "sending beacon..."
                                _stream.write "Beacon"
                                bsent++
                                setTimeout(repeat, @config.beaconInterval * 1000)
                            (err) => # finally
                                err ?= "beacon retry timeout, server no longer responding"
                                @log "final call on sending beacons, exiting with: " + (err ? "no errors")
                                try
                                    _stream.end()
                                    mx.destroy()
                                    stream.end()
                                catch err
                                    @log "error during client connection shutdown due to beacon timeout: "+err
                        )

                    when 'relay'
                        target = (Number) target
                        unless target in forwardingPorts
                            @log "request for relay to unsupported target port: #{target}"
                            _stream.end()
                            break

                        incoming = ''
                        request = null

                        _stream.on 'data', (chunk) =>
                            unless request
                                try
                                    @log "request received: "+chunk
                                    request = JSON.parse chunk
                                catch err
                                    @log "invalid relay request!"
                                    _stream.end()
                            else
                                @log "received some data: "+chunk
                                incoming += chunk

                        _stream.on 'end',  =>
                            @log "relaying following request to local:#{target} - "

                            roptions = url.parse request.url
                            roptions.method = request.method
                            roptions.headers = request.headers
                            roptions.agent = false
                            roptions.port = target

                            @log JSON.stringify roptions

                            timeout = false
                            relay = http.request roptions, (reply) =>
                                unless timeout
                                    @log "sending back reply"
                                    reply.setEncoding 'utf8'
                                    try
                                        _stream.write JSON.stringify
                                            statusCode: reply.statusCode,
                                            headers: reply.headers
                                        reply.pipe(_stream, {end:true})
                                    catch err
                                        @log "unable to write response back to requestor upstream bolt! error: " + err

                            relay.write incoming if incoming
                            relay.end()

                            relay.on 'end', =>
                                @log "no more data"

                            relay.setTimeout 20000, =>
                                @log "error during performing relay action! request timedout."
                                timeout = true
                                try
                                    _stream.write JSON.stringify
                                        statusCode: 408,
                                        headers: null
                                    _stream.end()
                                catch err
                                    @log "unable to write response code back to requestor upstream bolt! error: " + err

                                @log "[relay request timed out, sending 408]"

                            relay.on 'error', (err) =>
                                @log "[relay request failed with following error]"
                                @log err
                                try
                                    _stream.write JSON.stringify
                                        statusCode: 500,
                                        headers: null
                                    _stream.end()
                                catch err
                                    @log "unable to write response code back to requestor upstream bolt! error: " + err
                                @log "[relay request error, sending 500]"

                    else
                        @log "unsupported action/target supplied by mux connection: #{action}/#{target}"
                        _stream.end()

        )

        stream.on "error", (err) =>
            @log "client error during connection to #{host}:#{port} with: " + err
            @emit 'client.disconnect', stream

        stream.on "close", =>
            @log "client closed connection to: #{host}:#{port}"
            @emit 'client.disconnect', stream
        return stream

module.exports = StormBolt
