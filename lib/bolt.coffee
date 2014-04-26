tls = require("tls")
fs = require("fs")
http = require("http")
url = require('url')
util = require('util')

MuxDemux = require('mux-demux')

#Workaround - fix it later, Avoids DEPTH_ZERO_SELF_SIGNED_CERT error for self-signed certs
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

class stormflashbolt

    options = ''
    beaconInterval = ''
    beaconRetry = ''
    client = this
 
    #BoltConnection object details
    #   {
    #   cname: cname  
    #   stream: stream
    #   mux: mx
    #   forwardingports:5000 
    #   beaconMaxInterval:0  
    #   validityTimer: 0     
    #   }

    #array of the active BoltConnection Objects.
    boltConnections = []
    
    #Bolt Server clean up the Client connection at every cleanupInterval.
    cleanupInterval= (5 * 1000) # 5 seconds

    listConnections = ->
        util.log '[active bolt connections]'
        for entry in boltConnections
            util.log "cname: #{entry.cname}  forwardingports: #{entry.forwardingports} beaconMaxInterval: #{entry.beaconMaxInterval} validityTimer: #{entry.validitiyTimer}"

    constructor: (config) ->
        util.log 'stormflash bolt initializing...'
        @config = config

    start: (callback) ->
        util.log "this should actually take place of configure below..."
        
        ca = []                                                            
        chain = fs.readFileSync "#{@config.ca}", 'utf8'                    
        chain = chain.split "\n"                                           
        cacert = []                                                        
        for line in chain when line.length isnt 0                          
            cacert.push line                                               
            if line.match /-END CERTIFICATE-/                              
                ca.push cacert.join "\n"                                   
                cacert = []                                      

        if @config.beaconParams
            beaconInterval = @config.beaconParams.split(":")[0]
            beaconRetry = @config.beaconParams.split(":")[1]
            util.log "beaconInterval: #{beaconInterval} ,beaconRetry: #{beaconRetry}"
        
        if @config.remote || @config.local
            if @config.local
                options =
                    key: fs.readFileSync("#{@config.key}")
                    cert: fs.readFileSync("#{@config.cert}")
                    ca: ca
                    requestCert: true
                    rejectUnauthorized: true 
                util.log "Starting Bolt server...."
                @runServer()
            else
                options =
                    cert: fs.readFileSync("#{@config.cert}")
                    key: fs.readFileSync("#{@config.key}")
                    ca: ca
                    requestCert: true
                util.log "Starting Bolt client...."
                for host in @config.remote
                    serverHost = host.split(":")[0]
                    serverPort = host.split(":")[1]
                    util.log serverHost + ": " + serverPort 
                    @runClient serverHost, serverPort
        else
            callback new Error "Invalid bolt JSON!"

        @runProxy()

    runProxy: ->
        if @config.listen
            listenPort = @config.listen.split(":")[1]
            util.log 'Running proxy on listenPort: ' + listenPort

        # after initial data, invoke HTTP server listener on port
        acceptor = http.createServer().listen(listenPort)
        acceptor.on "request", (request,response) =>
            #util.log "[proxy] request from client: " + request.url
            if request.url == '/cname'
                res = []
                for entry in boltConnections
                    res.push
                        cname: entry.cname
                        forwardingports: entry.forwardingports
                        caddress: entry.stream.remoteAddress

                body = JSON.stringify res
                #util.log "[proxy] returning connections data: " + body
                response.writeHead(200, {
                    'Content-Length': body.length,
                    'Content-Type': 'application/json' })
                response.end(body,"utf8")
                return

            target = request.headers['stormflash-bolt-target']
            [ cname, port ] = target.split(':') if target
             
            if cname
                listConnections()
                match = (item for item in boltConnections when item.cname is cname)                
                entry = match[0] if match.length
                unless entry
                    error = "no such stormflash-bolt-target: "+target
                    util.log error
                    response.writeHead(404, {
                        'Content-Length': error.length,
                        'Content-Type': 'application/json',
                        'Connection': 'close' })
                    response.end(error,"utf8")
                    return

                util.log "[proxy] forwarding request to " + cname + " at " + entry.stream.remoteAddress

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
                                util.log "relay response received: "+ chunk
                                relayResponse = JSON.parse chunk
                                response.writeHead(relayResponse.statusCode, relayResponse.headers)                                
                                relay.pipe(response)
                            catch err
                                util.log "invalid relay response!"
                                relay.end()
                                return

                    relay.on "end", =>
                        util.log "no more data in relay"                          

                    request.on "data", (chunk) =>
                        util.log "read some data: "+chunk

                    request.on "end", =>
                        util.log "no more data in the request..."

    addConnection: (data) ->
        match = (item for item in boltConnections when item.cname is data.cname)
        entry = match[0] if match.length
        if entry
            entry.stream = data.stream
            entry.mux = data.mux
        else
            boltConnections.push data

        listConnections()

    removeConnection: (streamName) ->
        try
            util.log "found match: " + item.cname for item,index in boltConnections when item.cname is streamName
            for item,index in boltConnections when item.cname is streamName
                if item.cname
                    util.log "Splicing connection: " + item.cname
                    #boltConnections.splice(boltConnections.indexOf('item.cname'), 1)
                    boltConnections.splice(index, 1)
                    util.log "Spliced connection: " + streamName
            listConnections()
        catch err
            util.log err

    #This function reset the validityTimer to beaconMaxInterval. This function is called upon beacon reception.
    resetValidityTimer: (streamName) ->
        try
            util.log "resetValidityTimer: found match: " + item.cname for item,index in boltConnections when item.cname is streamName
            for item in boltConnections when item.cname is streamName
                item.validitiyTimer = item.beaconMaxInterval
                util.log "reseted the validtityTimer to #{item.validitiyTimer}"
                break
            listConnections()
        catch err
            util.log err

    #This function reduces the validityTimer by connectionTick values, and destroy the client connection if validity is 0
    #At every connectionTick time the fucntion is called.
    updateValidityTimer: (connectionTick)->
        try
            if boltConnections?
                for i in [0..boltConnections.length-1] 
                    boltConnections[i].validitiyTimer=(boltConnections[i].validitiyTimer - connectionTick)
                    if boltConnections[i].validitiyTimer < 1
                        boltConnections[i].stream.destroy()
                        @removeConnection(boltConnections[i].cname)
            listConnections()
        catch err
            util.log err


    isEmptyOrNullObject: (jsonObj) ->
        if (!jsonObj)
            util.log 'jsonObj not object'
            return true
        else
            for key, val of jsonObj
                if(jsonObj.hasOwnProperty(key))
                    return false
            util.log 'jsonObj is empty'
            return true

    # Method to start bolt server
    runServer: ->
        local = @config.local
        util.log 'In start bolt server: ' + local
        serverPort = local.split(":")[1]
        util.log "server port:" + serverPort
        serverConnection = tls.createServer options, (stream) =>
            util.log "TLS connection established with VCG client from: " + stream.remoteAddress
            util.log 'Debugging null certs issue : server authorizationError: ' + stream.authorizationError            
            certObj = stream.getPeerCertificate()
            jsonObj = JSON.stringify certObj 
            util.log 'certObj: ' + jsonObj 
            if @isEmptyOrNullObject certObj
                util.log 'unable to retrieve peer certificate!'
                util.log 'server connected ' + stream.authorized ? 'authorized' : 'unauthorized'
                stream.end()
                util.log 'stream end after certObj{}'
                return

            cname = certObj.subject.CN
            stream.name = cname
            stream.pipe(mx = MuxDemux()).pipe(stream)

            capability = mx.createReadStream('capability')
            capability.on 'data', (data) =>
                util.log "Received capability info from bolt client: " + data
                                
                if data.search('forwardingPorts') == 0
                    @addConnection
                        cname: cname,
                        stream: stream,
                        mux: mx,
                        forwardingports: data.split(':')[1],
                        beaconMaxInterval: data.split(':')[2],
                        validitiyTimer: data.split(':')[2]
                    
            mx.on 'connection', (_stream) =>
                #util.log "Server: some connection?",_stream.meta
                [ action, target ] = _stream.meta.split(':')
                util.log "Server: connection action #{action}  target #{target}"
                switch action
                    when 'beacon'
                        _stream.on 'data', (chunk) =>
                            util.log "Server: received on beacon #{chunk}, sending response back.."
                            @resetValidityTimer(stream.name)
                            _stream.write "Beacon:Response"
                            _stream.end
                        
            mx.on 'error', =>
                util.log "some error with mux connection"
                stream.destroy()         
            
            stream.on 'error', =>
                mx.destroy()
            
            stream.on "close",  =>
                util.log "Bolt client connection is closed for ID: " + stream.name
                @removeConnection stream.name            

        serverConnection.listen serverPort
        serverConnection.on 'error', (err) ->
            util.log 'server connection error :' + err.message
            try
                message = String(err.message)
                if (message.indexOf ('ECONNRESET')) >= 0
                    util.log 'throw error: ' + 'ECONNRESET'
                    throw new Error err
            catch e
                util.log 'error e' + e
                #process.exit(1)
        setInterval (=>
            util.log "Cleanuptimer triggered "
            @updateValidityTimer(cleanupInterval)
        ), cleanupInterval

    #reconnect logic for bolt client
    isReconnecting = false
    calledReconnectOnce = false

    reconnect: (host, port) ->
        retry = =>
            unless isReconnecting
                isReconnecting = true
                @runClient host,port
        setTimeout(retry, 1000)

    # Garbage collect every 2 sec
    # Run node with --expose-gc
    if gc?
        setInterval (
            () -> gc()
        ), 2000


    #Method to start bolt client
    runClient: (host, port) ->
        tls.SLAB_BUFFER_SIZE = 100 * 1024
        # try to connect to the server
        util.log "making connection to bolt server at: "+host+':'+port
        calledReconnectOnce = false
        beaconReqCount=0
        beaconRspCount=0
        timerhandler=null
        stream = tls.connect(port, host, options, =>
            if stream.authorized
                util.log "Successfully connected to bolt server"
            else
                util.log "Failed to authorize TLS connection. Could not connect to bolt server (ignored for now)"            
            stream.setKeepAlive(true, 60 * 1000) #Send keep-alive every 60 seconds
            stream.setEncoding 'utf8'
            stream.pipe(mx=MuxDemux()).pipe(stream)

            forwardingPorts = @config.local_forwarding_ports
            # beacon stream(duplex) creation
            ds=mx.createStream('beacon:beacon',{allowHalfOpen:true})

            ds.on 'data', (data) =>
                beaconRspCount++
                util.log "received beacon response data: " + data
                util.log "beaconRspCount " + beaconRspCount

            timerhandler=setInterval(()->
                beaconReqCount++
                ds.write "Beacon-Request:#{beaconInterval}:#{beaconRetry}"
                util.log "Beacon Request sent, beaconReqCount : " + beaconReqCount
            ,beaconInterval)

            #beaconmaxvalue is beaconinterval * retry.. server will wait till this time before delete the client connection.
            #beaconmaxvalue is communicated to the server in 'initial capability'
            beaconmaxvalue = beaconInterval*beaconRetry
            util.log "Beaconmaxvalue " + beaconmaxvalue

            mx.on "connection", (_stream) =>
                [ action, target ] = _stream.meta.split(':')
                util.log "Client: action #{action}  target #{target}"
                switch action
                    when 'capability'
                        util.log 'sending capability information...'
                        _stream.write "forwardingPorts:#{forwardingPorts}:#{beaconmaxvalue}"
                        _stream.end()

                    when 'relay'
                        target = (Number) target
                        unless target in forwardingPorts
                            util.log "request for relay to unsupported target port: #{target}"
                            _stream.end()
                            break

                        incoming = ''
                        request = null

                        _stream.on 'data', (chunk) =>
                            unless request
                                try
                                    util.log "request received: "+chunk
                                    request = JSON.parse chunk
                                catch err
                                    util.log "invalid relay request!"
                                    _stream.end()
                            else
                                util.log "received some data: "+chunk
                                incoming += chunk

                        _stream.on 'end',  =>
                            util.log "relaying following request to local:#{target} - "

                            roptions = url.parse request.url
                            roptions.method = request.method
                            roptions.headers = request.headers
                            roptions.agent = false
                            roptions.port = target

                            util.log JSON.stringify roptions

                            timeout = false
                            relay = http.request roptions, (reply) =>
                                unless timeout
                                    util.log "sending back reply"
                                    reply.setEncoding 'utf8'
                                    try
                                        _stream.write JSON.stringify
                                            statusCode: reply.statusCode,
                                            headers: reply.headers
                                        reply.pipe(_stream, {end:true})
                                    catch err
                                        util.log "unable to write response back to requestor upstream bolt! error: " + err

                            relay.write incoming if incoming
                            relay.end()

                            relay.on 'end', =>
                                util.log "no more data"

                            relay.setTimeout 20000, ->
                                util.log "error during performing relay action! request timedout."
                                timeout = true
                                try
                                    _stream.write JSON.stringify
                                        statusCode: 408,
                                        headers: null
                                    _stream.end()
                                catch err
                                    util.log "unable to write response code back to requestor upstream bolt! error: " + err

                                util.log "[relay request timed out, sending 408]"

                            relay.on 'error', (err) ->
                                util.log "[relay request failed with following error]"
                                util.log err
                                try
                                    _stream.write JSON.stringify
                                        statusCode: 500,
                                        headers: null
                                    _stream.end()
                                catch err
                                    util.log "unable to write response code back to requestor upstream bolt! error: " + err
                                util.log "[relay request error, sending 500]"

                    else
                        util.log "unsupported action/target supplied by mux connection: #{action}/#{target}"
                        _stream.end()

        )

        stream.on "error", (err) =>
            util.log 'client error: ' + err            
            isReconnecting = false
            calledReconnectOnce = true
            #clean up the existing beacon timer 
            clearInterval(timerhandler)
            @reconnect host, port

        stream.on "close", =>
            util.log 'client closed: '
            isReconnecting = false
            #clean up the existing beacon timer
            clearInterval(timerhandler)
            unless calledReconnectOnce
                @reconnect host, port        

module.exports = stormflashbolt
