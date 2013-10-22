tls = require("tls")
fs = require("fs")
http = require("http")
net = require('net')
url = require('url')

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
        
        ca = []                                                            
        chain = fs.readFileSync "#{@config.ca}", 'utf8'                    
        chain = chain.split "\n"                                           
        cacert = []                                                        
        for line in chain when line.length isnt 0                          
            cacert.push line                                               
            if line.match /-END CERTIFICATE-/                              
                ca.push cacert.join "\n"                                   
                cacert = []                                      
        
        if @config.remote || @config.local
            if @config.local
                options =
                    key: fs.readFileSync("#{@config.key}")
                    cert: fs.readFileSync("#{@config.cert}")
                    ca: ca
                    requestCert: true
                    rejectUnauthorized: false 
                console.log "bolt server"
                @runServer()
            else
                options =
                    cert: fs.readFileSync("#{@config.cert}")
                    key: fs.readFileSync("#{@config.key}")
                    ca: ca
                    requestCert: true
                console.log "bolt client"
                for host in @config.remote
                    serverHost = host.split(":")[0]
                    serverPort = host.split(":")[1]
                    console.log serverHost + ": " + serverPort 
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
                    relay = entry.mux.createStream('relay:'+ port, {allowHalfOpen:true})

                    relay.write JSON.stringify
                        method:  request.method,
                        url:     request.url,
                        headers: request.headers

                    # relay.write request.method + ' ' + request.url + " HTTP/1.1\r\n"
                    # relay.write 'cloudflash-bolt-target: '+request.headers['cloudflash-bolt-target']+"\r\n"
                    # relay.write "\r\n"

                    request.setEncoding 'utf8'
                    request.pipe(relay)

                    relayResponse = null
                    relay.on "data", (chunk) =>

                        unless relayResponse
                            try
                                console.log "relay response received: "+chunk
                                relayResponse = JSON.parse chunk
                                response.writeHead(relayResponse.statusCode, relayResponse.headers)
                                relay.pipe(response)
                            catch err
                                console.log "invalid relay response!"
                                relay.end()
                                return

                    relay.on "end", =>
                        console.log "no more data in relay"

                    request.on "data", (chunk) =>
                        console.log "read some data: "+chunk

                    request.on "end", =>
                        console.log "no more data in the request..."

    addConnection: (data) ->
        match = (item for item in boltConnections when item.cname is data.cname)
        entry = match[0] if match.length
        if entry
            entry.stream = data.stream
            entry.mux = data.mux
        else
            boltConnections.push data

        listConnections()

    isEmptyOrNullObject: (jsonObj) ->
        if (!jsonObj)
            return true
        else
            for key, val of jsonObj
                if(jsonObj.hasOwnProperty(key))
                    return false

            return true

    # Method to start bolt server
    runServer: ->
        local = @config.local
        console.log 'in start bolt: ' + local
        serverPort = local.split(":")[1]
        console.log "server port:" + serverPort
        tls.createServer(options, (stream) =>
            console.log "TLS connection established with VCG client from: " + stream.remoteAddress

            certObj = stream.getPeerCertificate()
            jsonObj = JSON.stringify certObj 
            console.log 'certObj: ' + jsonObj 
            if @isEmptyOrNullObject certObj
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
                        cname: cname,
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

            stream.setKeepAlive(true, 60 * 1000) #Send keep-alive every 60 seconds
            stream.setEncoding 'utf8'
            stream.pipe(mx=MuxDemux()).pipe(stream)

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
                        request = null

                        _stream.on 'data', (chunk) =>

                            unless request
                                try
                                    console.log "request received: "+chunk
                                    request = JSON.parse chunk
                                catch err
                                    console.log "invalid relay request!"
                                    _stream.end()
                            else
                                console.log "received some data: "+chunk
                                incoming += chunk

                        _stream.on 'end',  =>
                            console.log "relaying following request to local:#{target} - "

                            roptions = url.parse request.url
                            roptions.method = request.method
                            roptions.headers = request.headers
                            roptions.agent = false
                            roptions.port = target

                            console.log JSON.stringify roptions

                            timeout = false
                            relay = http.request roptions, (reply) =>
                                unless timeout
                                    console.log "sending back reply"
                                    reply.setEncoding 'utf8'

                                    try
                                        _stream.write JSON.stringify
                                            statusCode: reply.statusCode,
                                            headers: reply.headers
                                        reply.pipe(_stream, {end:true})
                                    catch err
                                        console.log "unable to write response back to requestor upstream bolt! error: " + err

                            relay.write incoming if incoming
                            relay.end()

                            relay.on 'end', =>
                                console.log "no more data"

                            relay.setTimeout 20000, ->
                                console.log "error during performing relay action! request timedout."
                                timeout = true
                                try
                                    _stream.write JSON.stringify
                                        statusCode: 408,
                                        headers: null
                                    _stream.end()
                                catch err
                                    console.log "unable to write response code back to requestor upstream bolt! error: " + err

                                console.log "[relay request timed out, sending 408]"

                            relay.on 'error', (err) ->
                                console.log "[relay request failed with following error]"
                                console.log err
                                _stream.write JSON.stringify
                                    statusCode: 500,
                                    headers: null
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
