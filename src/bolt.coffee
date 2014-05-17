
#Workaround - fix it later, Avoids DEPTH_ZERO_SELF_SIGNED_CERT error for self-signed certs
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

StormAgent = require 'stormagent'

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
        @connections = connections = {}

        # setup event handlers for server events
        @on 'server.connect', (cname, stream, mx) =>
            @log "server connect event triggered for cname - #{cname}"
            capability = mx.createReadStream 'capability'
            capability.on 'data', (capa) =>
                @log "received capability info from client:", capa
                # check for forwardingPorts?
                connections[cname] =
                    stream: stream
                    mux: mx
                    allowedPorts: capa.split(',') ? []
                    validity: @config.beaconValidity
                @log "Added new client in the connections list, cname - #{cname}"
                # should we close mux?
            bstream = mx.createStream 'beacon', { allowHalfOpen:true }
            bstream.on 'data', (beacon) =>
                @log "received beacon from client: #{cname}"
                connections[cname].validity = @config.beaconValidity # reset
                bstream.write "beacon:reply"
                #bstream.end()

        @on 'server.disconnect', (cname, stream, mx) =>
            @log "server disconnect event triggered for cname - #{cname}"
            mx.close()
            connections[cname] = null

    status: ->
        state = super
        state.uplink = @uplink ? null
        state.clients = @clients()
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

            running = true
            async.whilst(
                () => # test condition
                    running
                (repeat) =>
                    for key,entry of @connections
                        do (key,entry) =>
                            return unless entry? and entry.mx? and entry.stream?
                            @log "DEBUG: #{key} has validity=#{entry.validity}"
                            @connections[key].validity -= @repeatInterval
                            unless entry.validity > 1
                                try
                                    entry.mx.close()
                                    entry.stream.destroy()
                                catch err
                                    @log "unable to properly terminate expired client connection: "+err
                                delete @connections[key]
                                @log "removed expired client connection from #{key}"
                    setTimeout(repeat, @repeatInterval * 1000)
                (err) =>
                    @log "bolt server no longer running, validity checker stopping..."
            )
            server.on 'error', (err) =>
                @log "fatal issue with bolt server: "+err
                running = false
                @emit 'server.error', err

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
        # check for running the relay
        @relay(@config.relayPort) if @config.allowRelay

    clients: (key) ->
        if key?
            return unless key in @connections
            entry = @connections[key]
            res =
                cname: key
                ports: entry.allowedPorts
                address: entry.stream.remoteAddress
                validity: entry.validity
            return res

        # iterate through connections and return resulting set
        {
            cname: key
            ports: entry.allowedPorts
            address: entry.stream.remoteAddress
            validity: entry.validity
        } for key,entry of @connections

    relay: (port) ->
        unless port? and port > 0
            @log "need to pass in valid port for performing relay"
            return

        @log 'starting the relay on port ' + port
        # after initial data, invoke HTTP server listener on port
        acceptor = http.createServer().listen(port)
        acceptor.on "request", (request,response) =>
            #@log "[proxy] request from client: " + request.url
            if request.url == '/cname'
                res = []
                for key, entry of @connections
                    res.push
                        cname: key
                        forwardingports: entry.allowedPorts
                        caddress: entry.stream.remoteAddress

                body = JSON.stringify res
                @log "[proxy] returning connections data: " + body
                response.writeHead(200, {
                    'Content-Length': body.length,
                    'Content-Type': 'application/json' })
                response.end(body,"utf8")
                return

            target = request.headers['stormflash-bolt-target']
            [ cname, port ] = target.split(':') if target

            if cname
                @log "active client connections:", @clients
                entry = @connections[cname]
                unless entry
                    error = "no such stormflash-bolt-target: "+target
                    @log "error:", error
                    response.writeHead(404, {
                        'Content-Length': error.length,
                        'Content-Type': 'application/json',
                        'Connection': 'close' })
                    response.end(error,"utf8")
                    return

                @log "[proxy] forwarding request to " + cname + " at " + entry.stream.remoteAddress

                if entry.mux
                    relay = entry.mux.createStream('relay:'+ port, {allowHalfOpen:true})

                    relay.write JSON.stringify
                        method:  request.method,
                        url:     request.url,
                        headers: request.headers

                    # relay.write request.method + ' ' + request.url + " HTTP/1.1\r\n"
                    # relay.write 'stormflash-bolt-target: '+request.headers['stormflash-bolt-target']+"\r\n"
                    # relay.write "\r\n"

                    request.setEncoding 'utf8'
                    request.pipe(relay)
                    relayResponse = null
                    relay.on "data", (chunk) =>
                        unless relayResponse
                            try
                                @log "relay response received: "+ chunk
                                relayResponse = JSON.parse chunk
                                response.writeHead(relayResponse.statusCode, relayResponse.headers)
                                relay.pipe(response)
                            catch err
                                @log "invalid relay response!"
                                relay.end()
                                return

                    relay.on "end", =>
                        @log "no more data in relay"

                    request.on "data", (chunk) =>
                        @log "read some data: "+chunk

                    request.on "end", =>
                        @log "no more data in the request..."

    # Method to start bolt server
    listen: (port, options) ->
        @log "server port:" + port
        #@log "options: " + @inspect options
        server = tls.createServer options, (stream) =>
            try
                @log "TLS connection established with VCG client from: " + stream.remoteAddress
                @log 'Debugging null certs issue : server authorizationError: ' + stream.authorizationError
                certObj = stream.getPeerCertificate()
                cname = certObj.subject.CN

                stream.name = cname
                server.emit 'newconnection', cname, stream

                @log 'server connected ' + stream.authorized ? 'authorized' : 'unauthorized'

            catch error
                @log 'unable to retrieve peer certificate and authorize connection!'
                stream.end()
                return

        server.on 'newconnection', (cname, stream) =>
            @log 'connection event triggered for: '+ cname

            stream.pipe(mx = MuxDemux()).pipe(stream)
            @emit 'server.connect', cname, stream, mx

            stream.on "close", =>
                @log "Bolt client connection is closed for ID: " + stream.name
                @emit 'server.disconnect', cname, stream, mx

            stream.on 'error', ->
                mx.destroy()

            #TODO - What happens when Mux goes into error, should we call removeConnection here?
            mx.on 'error', ->
                stream.destroy()

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
            if stream.authorized
                @log "Successfully connected to bolt server"
                @uplink =
                    host: host
                    port: port
                    options: options
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
