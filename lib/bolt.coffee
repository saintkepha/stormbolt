@include = ->

    cloudflashbolt = require('./boltlib')
    bolt = new cloudflashbolt
    bolt.configure()

    @post '/boltserver': ->
        console.log 'IN POST'
        console.log 'header' + @req.header('content-type')
        console.log 'body: ' + JSON.stringify @body
        bolt.sendDataToClient @req, (res) =>
            unless res instanceof Error
                @send res
            else
                @next res
    @get '/cname': ->
        bolt.listBoltClients (res) =>
            unless res instanceof Error
                @send res
            else
                @next res
