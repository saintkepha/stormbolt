tls = require("tls")
fs = require("fs") 
fileops = require("fileops")
http = require("http")
boltjson = require('./boltutil')
util = require('util')

class cloudflashbolt
    
    boltClientList = []; boltClientData = []; boltClientSocket = ''
    options = ''; clientResponse = []
    #socketIdCounter = 0        
    client = this    

    constructor: ->
        console.log 'boltlib initialized'
        @boltJsonObj = boltjson.readBoltJson()      

    # Read from bolt.json config file and start bolt client or server accordingly.
    configure: (callback) ->            

        if @boltJsonObj.remote || @boltJsonObj.local
            local = @boltJsonObj.local
            if local
                options =
                    key: fs.readFileSync("#{@boltJsonObj.key}")
                    cert: fs.readFileSync("#{@boltJsonObj.cert}")
                    requestCert: true
                    rejectUnauthorized: false
                console.log "bolt server" 
                @boltServer()
            else
                options =
                    cert: fs.readFileSync("#{@boltJsonObj.cert}")
                    key: fs.readFileSync("#{@boltJsonObj.key}")
                console.log "bolt client"
                remoteHosts = @boltJsonObj.remote
                listen =  @boltJsonObj.listen                    
                if remoteHosts.length > 0
                    for host in remoteHosts
                        serverHost = host.split(":")[0]
                        serverPort = host.split(":")[1]
                        @boltClient serverHost, serverPort   
                
        else
            callback new Error "Invalid bolt JSON!"
                        
    listBoltClients: (callback) ->
        res = []        
        for clientData in boltClientData
            res.push clientData
        callback(res)

    # Method to start bolt server
    boltServer: ->        
        local = @boltJsonObj.local
        console.log 'in start bolt: ' + local        
        serverPort = local.split(":")[1]
        console.log "server port:" + serverPort 
        tls.createServer(options, (socket) =>
            console.log "TLS connection established with VCG client"
            #socket.id  = socketIdCounter++
            
            socket.setEncoding "utf8"
            boltClientList.push socket          
            socket.addListener "data", (data) =>                               
                console.log "connection from client :" + socket.remoteAddress
                console.log "Data received: " + data                    
                
                if data.search('forwardingPorts') == 0 
                    # store bolt client data in local memory
                    result = {}             
                    certObj = socket.getPeerCertificate()
                    console.log 'certObj: ' + JSON.stringify certObj
                    cname = certObj.subject.CN                                
                    result.forwardingports = data.split(':')[1]
                    result.cname = cname
                    socket.name = cname
                    #result.clientaddr = socket.remoteAddress
                    result.sockName = cname 
                    #result.socketId = socket.name                    
                    console.log 'cname result : ' + JSON.stringify result     
                    boltClientData.push result
                else
                    # Handel response from webservice                    
                    console.log 'socket.name: ' + socket.name
                    respData = {}
                    respData.id  = socket.getPeerCertificate().subject.CN
                    respData.data = data
                    clientResponse.push respData
                    console.log "final res length in listener :" + clientResponse.length

            socket.addListener "close",  =>
                console.log "bolt client is closed :" + socket.name                
                boltClientDataTemp = []
                console.log "bolt client list size before disconnect " + boltClientData.length
                for clientData in boltClientData
                    if clientData.sockName != socket.name
                        boltClientDataTemp.push clientData
                
                boltClientData = boltClientDataTemp
                console.log "bolt client list size after disconnect " + boltClientData.length                   
                
        ).listen serverPort               

    #Method to forward equests to bolt clients
    sendDataToClient: (request, callback) ->
        #console.log 'request object server: ' + util.inspect(request)       
        if request.header('cloudflash-bolt-target')
                boltTarget = request.header('cloudflash-bolt-target')
                boltTarget = boltTarget.split(":")[0]
                entry = ''; serverRequest = {}
                # check for cname existence
                for clientData in boltClientData
                    if clientData.cname == boltTarget
                        entry = clientData
                        break
                # if cname exist process request   
                if entry
                    for socket in boltClientList
                        #if socket.remoteAddress == entry.clientaddr
                        if socket.name == entry.sockName
                            boltClientSocket = socket
                            console.log "client exists"
                            break
        
                    console.log "server conn address :" + boltClientSocket.remoteAddress  
                    if request.method == "POST" || request.method == "PUT"                 
                        serverRequest.body = request.body
                        serverRequest.header = request.header('content-type')
                        serverRequest.length = request.header('Content-Length')
                        if  request.header('Accept')
                            serverRequest.accept = request.header('Accept')

                    
                    serverRequest.path = request.path
                    serverRequest.method = request.method
                    serverRequest.target = request.header('cloudflash-bolt-target')
                    
                    boltClientSocket.write JSON.stringify(serverRequest)
                      
                    
                    setTimeout (->
                        console.log 'boltTarget name:' + boltClientSocket.name
                        tempBuffer = []; result = new Error "delay in receiving response!"
                        console.log "final res length in settimeout :" + clientResponse.length
                        for res in clientResponse
                            if res.id == boltTarget
                                console.log 'res.id: ' + res.id
                                result = res.data
                            else
                                tempBuffer.push res
                        console.log 'clientResponse: ' + JSON.stringify clientResponse
                        clientResponse = tempBuffer                        
                        callback result                        
                    ), 10000
                else
                    return callback new Error "bolt cname entry not found!" 
        else
            return callback new Error "bolt target missing!"
    
    #Method to start bolt client
    boltClient: (host, port) ->
        # try to connect to the server
        forwardingPorts = @boltJsonObj.local_forwarding_ports
        client.socket = tls.connect(port, host, options, =>            
            if client.socket.authorized
                console.log "Successfully connected to bolt server"
                result = "forwardingPorts:#{forwardingPorts}"
                client.socket.write result
            else
                #using self signed certs for intergration testing. Later get rid of this.
                result = "forwardingPorts:#{forwardingPorts}"
                client.socket.write result
                console.log "Failed to authorize TLS connection. Could not connect to bolt server"                
        )

        client.socket.addListener "data", (data) ->
            res = {}
            console.log "Data received from bolt server: " + data            
            recvData = JSON.parse data
            
            boltTarget = recvData.target
            boltTargetPort = boltTarget.split(":")[1]
            boltTargetPort = (Number) boltTargetPort
            console.log 'boltTargetPort: ' + boltTargetPort
            portexists = false
            console.log 'forwardingPorts: ' + forwardingPorts
            #check boltTargetPort is part of forwardingPorts
            for localPort in forwardingPorts                
                if localPort == boltTargetPort
                    console.log 'port exist'
                    portexists = true
                    break

            if portexists                      
                request = new http.ClientRequest(
                    hostname: "localhost"
                    port: boltTargetPort
                    path: recvData.path
                    method: recvData.method
                )

                if recvData.method == "POST" || recvData.method == "PUT" 
                    request.setHeader("Content-Type",recvData.header)
                    request.setHeader("Content-Length",recvData.length)
                    if recvData.accept
                        request.setHeader("Accept",recvData.accept)

                    if recvData.header.search "application/json" == 0 
                        request.write JSON.stringify(recvData.body)
                    else
                        request.write recvData.body              

                
                request.end()                
                request.on "error", (err) ->
                    console.log "error: " + err                    
                    res.error = err                    
                    client.socket.write JSON.stringify(res)
                #console.log 'request object client: ' + util.inspect(request)  
                request.on "response", (response) ->                    
                    console.log "STATUS: " + response.statusCode
                    response.setEncoding "utf8"                    
                    response.on "data", (resFromCF) ->
                        console.log "response from cloudflash: " + resFromCF
                        if response.statusCode == 200 || response.statusCode == 204
                            #console.log 'response object client: ' + util.inspect(response)  
                            client.socket.write resFromCF
                        else                            
                            res.error = resFromCF
                            client.socket.write JSON.stringify(res)                        

            else
                res.error = "Bolt Target Port not part of local forwarding ports managed by the client"
                client.socket.write JSON.stringify(res)
                  
module.exports = cloudflashbolt
