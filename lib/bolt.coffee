@include = ->

    cloudflashbolt = require('./boltlib')
    bolt = new cloudflashbolt    
    bolt.configure (res) =>
        if res instanceof Error
             console.log 'error: ' + res
    
    @get '/*': -> 
        console.log 'IN GET' + @request.path
        if @request.path == '/cname'
            bolt.listBoltClients (res) =>
                unless res instanceof Error
                    @send res
                else
                    @next res
        else
            bolt.sendDataToClient @request, (res) =>
                unless res instanceof Error
                    @send res
                else
                    @next res

    @post '/*': ->        
        console.log 'IN POST'        
        bolt.sendDataToClient @request, (res) =>
            unless res instanceof Error
                @send res
            else
                @next res
    @put '/*': ->        
        console.log 'IN PUT'        
        bolt.sendDataToClient @request, (res) =>
            unless res instanceof Error
                @send res
            else
                @next res
    @del '/*': ->        
        console.log 'IN DEL'        
        bolt.sendDataToClient @request, (res) =>
            unless res instanceof Error
                @send res
            else
                @next res   
    
