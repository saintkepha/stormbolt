@include = ->

    cloudflashbolt = require('./boltlib')
    bolt = new cloudflashbolt

    @get '/*': ->
        console.log 'IN GET' + @request.path
        bolt = null; bolt = new cloudflashbolt
        if @request.path == '/cname'
            bolt.listBoltClients (res) =>
                unless res instanceof Error
                    @send res
                else
                    @next res
        else
            bolt.sendDataToClient @request, (res) =>
                resData = JSON.parse res
                @response.status(resData.status)
                # commented for now as issues seen with express version
                #@response.set(resData.headers)
                console.log 'resData.data: ' + resData.data
                if resData.status == 200 || resData.status == 204 || resData.status == 202
                    @send resData.data
                else
                    console.log 'in else' + JSON.stringify resData
                    @next resData.data


    @post '/*': ->
        console.log 'IN POST'
        bolt = null; bolt = new cloudflashbolt
        bolt.sendDataToClient @request, (res) =>
            resData = JSON.parse res
            @response.status(resData.status)
            #@response.set(resData.headers)
            if resData.status == 200 || resData.status == 204 || resData.status == 202
                @send resData.data
            else
                console.log 'in else'
                @next resData.data
    @put '/*': ->
        console.log 'IN PUT'
        bolt = null; bolt = new cloudflashbolt
        bolt.sendDataToClient @request, (res) =>
            resData = JSON.parse res
            @response.status(resData.status)
            #@response.set(resData.headers)
            if resData.status == 200 || resData.status == 204 || resData.status == 202
                @send resData.data
            else
                console.log 'in else'
                @next resData.data

    @del '/*': ->
        console.log 'IN DEL'
        bolt = null; bolt = new cloudflashbolt
        bolt.sendDataToClient @request, (res) =>
            resData = JSON.parse res
            @response.status(resData.status)
            #@response.set(resData.headers)
            if resData.status == 200 || resData.status == 204 || resData.status == 202
                @send resData.data
            else
                console.log 'in else'
                @next resData.data
