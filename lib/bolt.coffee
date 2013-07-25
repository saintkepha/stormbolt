tls = require("tls")
fs = require("fs")
http = require("http")
net = require('net')

MuxDemux = require('mux-demux')

#Workaround - fix it later, Avoids DEPTH_ZERO_SELF_SIGNED_CERT error for self-signed certs
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

class cloudflashbolt

    options = ''
    client = this

    boltConnections = []

    listConnections = ->
        console.log '[active bolt connections]'
        for entry in boltConnections
            console.log entry.cname + ": " + entry.forwardingports

    constructor: (config) ->
        console.log 'boltlib initialized'
        @config = config

    start: (callback) ->
        console.log "this should actually take place of configure below..."
        if @config.remote || @config.local
            if @config.local
                options =
                    key: fs.readFileSync("#{@config.key}")
                    cert: fs.readFileSync("#{@config.cert}")
                    requestCert: true
                    rejectUnauthorized: false
                console.log "bolt server"
                @runServer()
            else
                options =
                    cert: fs.readFileSync("#{@config.cert}")
                    key: fs.readFileSync("#{@config.key}")
                console.log "bolt client"
                for host in @config.remote
                    serverHost = host.split(":")[0]
                    serverPort = host.split(":")[1]
                    @runClient serverHost, serverPort
        else
            callback new Error "Invalid bolt JSON!"

        @runProxy()

    runProxy: ->
        if @config.listen
            listenPort = @config.listen.split(":")[1]
            console.log 'running proxy on listenPort: ' + listenPort

        # after initial data, invoke HTTP server listener on port
        acceptor = http.createServer().listen(listenPort)
        acceptor.on "request", (request,response) =>
            console.log "[proxy] request from client: " + request.url
            if request.url == '/cname'
                res = []
                for entry in boltConnections
                    res.push
                        cname: entry.cname
                        forwardingports: entry.forwardingports
                        caddress: entry.stream.remoteAddress

                body = JSON.stringify res
                console.log "[proxy] returning connections data: " + body
                response.writeHead(200, {
                    'Content-Length': body.length,
                    'Content-Type': 'application/json' })
                response.end(body,"utf8")
                return

            target = request.headers['cloudflash-bolt-target']
            [ cname, port ] = target.split(':') if target

            if cname
                listConnections()
                match = (item for item in boltConnections when item.cname is cname)
                entry = match[0] if match.length
                unless entry
                    error = "no such cloudflash-bolt-target: "+target
                    console.log error
                    response.writeHead(404, {
                        'Content-Length': error.length,
                        'Content-Type': 'application/json',
                        'Connection': 'close' })
                    response.end(body,"utf8")
                    return

                console.log "[proxy] forwarding request to " + cname + " at " + entry.stream.remoteAddress

                if entry.mux
                    relay = entry.mux.createStream('relay:'+ port)
                    request.pipe(relay).pipe(response)

    addConnection: (data) ->
        match = (item for item in boltConnections when item.cname is cname)
        entry = match[0] if match.length
        if entry
            entry.stream = data.stream
            entry.mux = data.mux
        else
            boltConnections.push data

        listConnections()

    # Method to start bolt server
    runServer: ->
        local = @config.local
        console.log 'in start bolt: ' + local
        serverPort = local.split(":")[1]
        console.log "server port:" + serverPort
        tls.createServer(options, (stream) =>
            console.log "TLS connection established with VCG client from: " + stream.remoteAddress

            #stream.setEncoding "utf8"
            #socket.setKeepAlive(true,1000)

            certObj = stream.getPeerCertificate()
            console.log 'certObj: ' + JSON.stringify certObj
            unless certObj.subject
                console.log 'unable to retrieve peer certificate!'
                stream.end()
                return

            cname = certObj.subject.CN
            stream.name = cname
            stream.pipe(mx = MuxDemux()).pipe(stream)

            capability = mx.createReadStream('capability')
            capability.on 'data', (data) =>
                console.log "received capability info from bolt client: " + data
                if data.search('forwardingPorts') == 0
                    @addConnection
                        cname: cname
                        stream: stream,
                        mux: mx,
                        forwardingports: data.split(':')[1]

            mx.on 'connection', (_stream) =>
                console.log "some connection?"

            mx.on 'error', =>
                console.log "some error with mux connection"
                stream.destroy()

            stream.on 'error', =>
                mx.destroy()

            stream.on "close",  =>
                console.log "bolt client connection is closed for ID: " + stream.name
                try
                    console.log "found match: " + item.cname for item,index in boltConnections when item.cname is stream.name
                    for item,index in boltConnections when item.cname is stream.name
                        if item.cname
                            console.log "Splicing connection: " + item.cname
                            #boltConnections.splice(boltConnections.indexOf('item.cname'), 1)
                            boltConnections.splice(index, 1)
                            console.log "Spliced connection: " + stream.name
                    listConnections()
                catch err
                    console.log err

        ).listen serverPort

    #reconnect logic for bolt client
    isReconnecting = false

    reconnect: (host, port) ->
        retry = =>
            unless isReconnecting
                isReconnecting = true
                @runClient host,port
        setTimeout(retry, 1000)

    #Method to start bolt client
    runClient: (host, port) ->
        # try to connect to the server
        forwardingPorts = @config.local_forwarding_ports
        console.log "making connection to bolt server at: "+host+':'+port
        stream = tls.connect(port, host, options, =>
            if stream.authorized
                console.log "Successfully connected to bolt server"
            else
                console.log "Failed to authorize TLS connection. Could not connect to bolt server (ignored for now)"

            stream.pipe(mx=MuxDemux()).pipe(stream)

            # capability = mx.createWriteStream('capability')
            # capability.write "forwardingPorts:#{forwardingPorts}"
            # capability.end()

            mx.on "connection", (_stream) =>
                [ action, target ] = _stream.meta.split(':')
                switch action
                    when 'capability'
                        _stream.write "forwardingPorts:#{forwardingPorts}"
                        _stream.end()

                    when 'relay'
                        target = (Number) target
                        unless target in forwardingPorts
                            console.log "request for relay to unsupported target port: #{target}"
                            _stream.end()
                            break

                        incoming = ''
                        _stream.on 'data', (chunk) =>
                            incoming += chunk

                        _stream.on 'end', =>
                            console.log "relaying following request to local:#{target} - "
                            console.log incoming

                            relay = net.connect target
                            relay.write incoming
                            relay.pipe(_stream, {end:true})

                            relay.setTimeout 20000, ->
                                console.log "error during performing relay action! request timedout."
                                _stream.end()

                            relay.on 'error', (err) ->
                                console.log err
                                _stream.end()

                    else
                        console.log "unsupported action/target supplied by mux connection: #{action}/#{target}"
                        _stream.end()

        )

        stream.on "error", (err) =>
            console.log 'client error: ' + err
            isReconnecting = false
            @reconnect host, port

        stream.on "close", =>
            console.log 'client closed: '
            isReconnecting = false
            @reconnect host, port

module.exports = cloudflashbolt
