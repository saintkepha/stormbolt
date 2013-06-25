tls = require("tls")
fs = require("fs") 
fileops = require("fileops")
validate = require('json-schema').validate
http = require("http")
boltjson = require('./commonfunction')


class cloudflashbolt
    
    boltClientList = [] 
    boltClientData = []
    boltClientSocket = ''
    local = ''; listen = ''; options = ''
    finalResp = ''
    forwardingPorts = []
    socketIdCounter = 0
        
    client = this
    cname = ''

    constructor: ->
        console.log 'boltlib initialized'       

    # Read from bolt.json config file and start bolt client or server accordingly.
    configure: ->

        boltContent = boltjson.readBoltJson()       
        @boltJsonObj = boltContent        

        if @boltJsonObj.remote || @boltJsonObj.local
            local = @boltJsonObj.local
            if local
                options =
                    key: fs.readFileSync("#{@boltJsonObj.key}")
                    cert: fs.readFileSync("#{@boltJsonObj.cert}")
                console.log "bolt server" 
                @boltServer()
            else
                options =
                    cert: fs.readFileSync("#{@boltJsonObj.cert}")
                    ca: fs.readFileSync("#{@boltJsonObj.ca}")
                console.log "bolt client"
                remoteHosts = @boltJsonObj.remote
                listen =  @boltJsonObj.listen    
                forwardingPorts = @boltJsonObj.local_forwarding_ports     
                if remoteHosts.length > 0
                    for host in remoteHosts
                        serverHost = host.split(":")[0]
                        serverPort = host.split(":")[1]
                        @boltClient serverHost, serverPort  
                
        else
            return new Error "Invalid bolt JSON!"
                        
    listBoltClients: (callback) ->
        res = []        
        for clientData in boltClientData
            res.push clientData
        callback(res)

    # Method to start bolt server
    boltServer: ->
        console.log 'in start bolt: ' + local
        serverPort = local.split(":")[1]
        console.log "server port:" + serverPort 
        tls.createServer(options, (socket) =>
            console.log "TLS connection established with VCG client"
            socket.id  = socketIdCounter++
            socket.setEncoding "utf8"
            boltClientList.push socket          
            socket.addListener "data", (data) =>
                finalResp = ''
                console.log "connection from client :" + socket.remoteAddress
                console.log "Data received: " + data
                result = JSON.parse data
                if result.cname
                    result.clientaddr = socket.remoteAddress
                    result.socketId = socket.id                    
                    console.log 'cname result : ' + result     
                    boltClientData.push result
                else
                    finalResp = data 

            socket.addListener "close",  =>
                console.log "bolt client is closed :" + socket.id
                bname = ''
                boltClientDataTemp = []
                console.log "before from DB" + boltClientData.length
                for clientData in boltClientData
                    if clientData.socketId != socket.id
                        boltClientDataTemp.push clientData
                
                boltClientData = boltClientDataTemp
                console.log "Bolt client has been removed from DB" + boltClientData.length
                   
                
        ).listen serverPort               

    #Method to forward equests to bolt clients
    sendDataToClient: (request, callback) ->
        serverRequest = {}; data = ''
        boltTarget = request.header('cloudflash-bolt-target')
        boltTarget = boltTarget.split(":")[0]
        if boltTarget
                entry = ''
                for clientData in boltClientData
                    if clientData.cname == boltTarget
                        entry = clientData
                        break
                    
                if entry
                    for socket in boltClientList
                        if socket.remoteAddress == entry.clientaddr
                            boltClientSocket = socket
                            console.log "client exists"
                            break
        
                    console.log "server conn address :" + boltClientSocket.remoteAddress
                     
                    serverRequest.body = request.body
                    serverRequest.header = request.header('content-type')
                    serverRequest.target = request.header('cloudflash-bolt-target')

                    if serverRequest.header.search "application/json" == 0 
                        boltClientSocket.write JSON.stringify(serverRequest)
                    else
                        boltClientSocket.write serverRequest

                    setTimeout (->
                        if finalResp
                            console.log 'finalResp in settimeout: ' + finalResp
                            callback finalResp
                        else
                            callback new Error "delay in receiving response!"
                    ), 1000
                else
                    return callback new Error "bolt cname entry not found!" 
        else
                return callback new Error "bolt target missing!"
        
      
    #Method to start bolt client
    boltClient: (host, port) ->
        # try to connect to the server
        client.socket = tls.connect(port, host, options, ->
            if client.socket.authorized
                console.log "Successfully connected to bolt server"
                certObj = client.socket.getPeerCertificate()               
                cname = certObj.subject.CN
                console.log 'cname: ' + cname
                result = {}; result.cname = cname; result.port = forwardingPorts
                client.socket.write JSON.stringify result
            else
                #Something may be wrong with your certificates
                console.log "Failed to authorize TLS connection. Could not connect to bolt server "
                console.log client.socket.authorizationError
                return new Error "Failed to authorize TLS connection!"
        )

        client.socket.addListener "data", (data) ->
            console.log "Data received from server: " + data            
            recvData = JSON.parse data
            
            boltTarget = recvData.target
            boltTargetPort = boltTarget.split(":")[1]
            boltTargetPort = (Number) boltTargetPort
            console.log 'boltTargetPort: ' + boltTargetPort
            portexists = false
            console.log 'forwardingPorts: ' + forwardingPorts
            for localPort in forwardingPorts
                console.log  'in if forwardingPorts' + localPort
                if localPort == boltTargetPort
                    console.log 'port exist'
                    portexists = true
                    break

            if portexists        
                request = new http.ClientRequest(
                    hostname: "localhost"
                    port: boltTargetPort
                    path: recvData.body.path
                    method: recvData.body.type
                )  
                request.setHeader("Content-Type",recvData.header)
                if recvData.header.search "application/json" == 0 
                    request.write JSON.stringify(recvData.body.body)
                else
                    request.write recvData.body.body  
    
                request.end()
                request.on "response", (response) ->
                    console.log "STATUS: " + response.statusCode
                    response.setEncoding "utf8"
                    response.on "data", (resFromCF) ->
                        console.log "response from cloudflash: " + resFromCF  
                        client.socket.write resFromCF 

            else
                console.log "Bolt Target Port is not part of local forwarding ports managed by the client"
        
                  
module.exports = cloudflashbolt

