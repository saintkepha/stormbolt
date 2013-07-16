tls = require("tls")
fs = require("fs")
fileops = require("fileops")
http = require("http")
util = require('util')
url  = require('url')
querystring = require('querystring')

class cloudflashbolt

    options = ''
    client = this

    boltConnections = []

    listConnections = ->
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
            cname = target.split(':')[0] if target

            if cname
                match = (item for item in boltConnections when item.cname is cname)
                entry = match[0] if match.length
                unless entry
                    error = "no such cloudflash-bolt-target: "+target
                    response.writeHead(404, {
                        'Content-Length': error.length,
                        'Content-Type': 'application/json' })
                    response.end(body,"utf8")
                    return

                console.log "[proxy] forwarding request to " + cname + " at " + entry.stream.remoteAddress

                # m2m = MuxDemux()
                # m2m.on 'connection', (stream) =>
                #     stream.on 'data', (data) =>
                #         console.log data

                # request.pipe(m2m).pipe(response)

                entry.stream.on "readable", =>
                    console.log "[proxy] forwarding response from client"
                    entry.stream.pipe(response, {end: true})

                request.on "pipe", =>
                    console.log "[proxy] client request piped..."

                # proxy = http.createClient()
                # preq = proxy.request(request.method,request.url,request.headers)

                # preq.on "response", (pres) =>
                #     pres.pipe(response)

                body = ''
                request.on "data", (chunk) =>
                    console.log 'read: ' + chunk
                    body += chunk

                request.on "end", =>
                    console.log "[proxy] client request ended..."
                    data = JSON.stringify
                        req: querystring.stringify request
                        headers: request.headers
                        body: body

                    buf = new Buffer 4
                    buf.writeUInt32LE(data.length,0)

                    console.log data
                    entry.stream.write buf
                    entry.stream.write data

    # Method to start bolt server
    runServer: ->
        local = @config.local
        console.log 'in start bolt: ' + local
        serverPort = local.split(":")[1]
        console.log "server port:" + serverPort
        tls.createServer(options, (stream) =>
            console.log "TLS connection established with VCG client from: " + stream.remoteAddress

            stream.setEncoding "utf8"
            #socket.setKeepAlive(true,1000)

            certObj = stream.getPeerCertificate()
            console.log 'certObj: ' + JSON.stringify certObj
            unless certObj.subject
                console.log 'unable to retrieve peer certificate!'
                stream.end()
                return

            cname = certObj.subject.CN
            stream.name = cname

            # mdm = MuxDemux()
            # mdm.on 'connection', (bstream) =>
            #     bstream.on 'data', (data) =>
            #         console.log data

            # stream.pipe(mdm).pipe(upstream)


            # boltConnections.push
            #     cname: cname
            #     stream: stream
            #     forwardingports: '5000'

            # listConnections()

            stream.once "readable", ->
                data = stream.read()
                console.log "Data received: " + data

                if data.search('forwardingPorts') == 0
                    # store bolt client data in local memory
                    result = {}

                    match = (item for item in boltConnections when item.cname is cname)
                    entry = match[0] if match.length
                    if entry
                        entry.stream = stream
                    else
                        boltConnections.push
                            cname: cname
                            stream: stream,
                            forwardingports: data.split(':')[1]

                    listConnections()

            stream.on "close",  =>
                console.log "bolt client connection is closed:" + stream.name
                boltConnections.splice(index, 1) for index, item in boltConnections when item.cname is stream.name
                listConnections()

            # acceptor = http.createServer()
            # acceptor.on "connect", (request,csock, head) =>
            #     console.log "Data received from bolt client: " + request.url
            #     stream.pipe(csock)
            #     csock.pipe(stream)

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
                result = "forwardingPorts:#{forwardingPorts}"
                stream.write result
            else
                #using self signed certs for intergration testing. Later get rid of this.
                result = "forwardingPorts:#{forwardingPorts}"
                stream.write result
                console.log "Failed to authorize TLS connection. Could not connect to bolt server"
        )

        stream.on "error", (err) =>
            console.log 'client error: ' + err
            isReconnecting = false
            @reconnect host, port

        stream.on "close", =>
            console.log 'client closed: '
            isReconnecting = false
            @reconnect host, port

        relay = (reqobj) =>
            orequest = querystring.parse reqobj.req
            roptions = url.parse(orequest.url)
            roptions.method = orequest.method
            roptions.agent = false
#            roptions.headers = reqobj.headers

            target = reqobj.headers['cloudflash-bolt-target']
            roptions.hostname = "localhost"
            roptions.port = (Number) target.split(':')[1]
            unless roptions.port in forwardingPorts
                console.log 'port does not exist'
                error = 'unauthorized port forwarding request!'
                stream.write('HTTP/1.1 500 '+error+'\r\n\r\n')
                stream.end()
                return

            console.log 'making http.request with options: ' + JSON.stringify roptions
            connector = http.request roptions, (targetResponse) =>
                console.log 'setting up reply back to stream'

                body = ''
                targetResponse.on 'data', (chunk) =>
                    console.log 'read: '+chunk
                    body += chunk

                targetResponse.on 'end', =>
                    console.log 'http request is over'
                    stream.write body

                stream.setEncoding('utf8')
                targetResponse.pipe(stream, {end: false})
                targetResponse.resume()

            connector.setTimeout 5000, ->
                error = "error during performing http request! request timedout."
                console.log error
                try
                    stream.write('HTTP/1.1 500 '+error+'\r\n\r\n')
                catch err
                    console.log err

            connector.on "error", (err) =>
                error = "error during performing http request!"
                console.log error
                try
                    stream.write('HTTP/1.1 500 '+error+'\r\n\r\n')
                catch err
                    console.log err
            connector.end()


        incoming = ''
        len = 0

        stream.on "data", (chunk) =>
            temp = ''
            unless incoming
                len = chunk.readUInt32LE(0)
                incoming = chunk.slice(4)
            else
                if incoming.length + chunk.length <= len
                    incoming += chunk
                else
                    offset = len - incoming.length
                    incoming += chunk.slice(0,offset)
                    temp = chunk.slice(offset)

            if incoming.length == len
                console.log 'processed incoming with '+incoming.length+' out of '+len
                relay JSON.parse incoming
                incoming = temp

module.exports = cloudflashbolt
