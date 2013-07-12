boltjson = require('./lib/boltutil')

listenPort = ''; 
boltJsonObj = boltjson.readBoltJson()
listen = boltJsonObj.listen
if listen    
    listenPort = listen.split(":")[1]
    console.log 'listenPort: ' + listenPort    
    
{@app} = require('zappajs') listenPort, ->
    @configure =>
      @use 'bodyParser', 'methodOverride', @app.router, 'static'
      @set 'basepath': '/v1.0'

    @configure
      development: => @use errorHandler: {dumpExceptions: on, showStack: on}
      production: => @use 'errorHandler'

    @enable 'serve jquery', 'minify'
    
    @include './lib/bolt'

