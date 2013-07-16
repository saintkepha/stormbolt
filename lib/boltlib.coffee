tls = require("tls")
fs = require("fs")
fileops = require("fileops")
http = require("http")
util = require('util')
querystring = require('querystring')

class cloudflashbolt

    options = ''
    client = this

    boltConnections = {}

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
            console.log "[proxy] request from client: " + JSON.stringify request
            if request.url == '/cname'
                res = []
                for cname,entry in boltConnections
                    res.push
                        cname: cname
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
                console.log "[proxy] forwarding request to " + cname
                entry = boltConnections[cname]
                entry.stream.on "readable", =>
                    console.log "[proxy] sending response from client"
                    boltClient.pipe(response, {end:true})

                request.pipe(entry.stream, {end:true})

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

            stream.once "data", (data) ->
                console.log "Data received: " + data

                if data.search('forwardingPorts') == 0
                    # store bolt client data in local memory
                    result = {}
                    certObj = stream.getPeerCertificate()
                    console.log 'certObj: ' + JSON.stringify certObj
                    cname = certObj.subject.CN
                    stream.name = cname

                    boltConnections[cname] =
                        stream: stream,
                        forwardingports: data.split(':')[1]

                    console.log "current data in boltConnections: " + JSON.stringify boltConnections

            stream.on "close",  =>
                console.log "bolt client is closed :" + stream.name
                delete boltConnections[stream.name]

        ).listen serverPort

    #reconnect logic for bolt client
    reconnect: (host, port) ->
        setTimeout(@runClient host, port, 1000)

    fillLocalErrorResponse: (status,headers,data) ->
        res = {}
        res.status = status
        res.headers = headers
        res.data = data
        return res

    #Method to start bolt client
    runClient: (host, port) ->
        # try to connect to the server
        forwardingPorts = @config.local_forwarding_ports
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

        stream.setEncoding("utf8")

        stream.on "error", (err) =>
            console.log 'client error: ' + err
            @reconnect host, port

        stream.on "close", =>
            console.log 'client closed: '
            @reconnect host, port

        acceptor = http.createServer().listen(stream)
        acceptor.on "request", (request,response) =>
            console.log "Data received from bolt server: " + JSON.stringify request
            console.log('request ' + request.url);

            target = request.headers['cloudflash-bolt-target']
            roptions = require('url').parse(request.url);
            roptions.hostname = "localhost"
            roptions.port = (Number) target.split(':')[1]
            unless roptions.port in forwardingPorts
                console.log 'port does not exist'
                error = 'unauthorized port forwarding request!'
                response.writeHead(500, {
                    'Content-Length': error.length,
                    'Content-Type': 'text/plain' })
                response.end()
                return

            roptions.headers = request.headers;
            roptions.method = request.method;
            roptions.agent = false;

            console.log 'making http.request with options: ' + roptions
            connector = http.request roptions, (targetResponse) =>
                console.log response
                targetResponse.pipe(response, {end:true} )

            request.pipe(connector, {end:true} )

module.exports = cloudflashbolt
