argv = require('optimist')
    .usage('Start cloudflash-bolt with a configuration file.\nUsage: $0')
    .demand('f')
    .default('f','/etc/bolt/bolt.json')
    .alias('f', 'file')
    .describe('f', 'location of bolt configuration file')
    .argv

config = ''
fileops = require("fileops")
res =  fileops.fileExistsSync argv.file
unless res instanceof Error
    boltContent = fileops.readFileSync argv.file
    config = JSON.parse boltContent
else
    return new Error "file does not exist! " + res

if config.listen
    listenPort = config.listen.split(":")[1]
    console.log 'listenPort: ' + listenPort

#cloudflashbolt = require './lib/boltlib'
#bolt = new cloudflashbolt config
#bolt.start

{@app} = require('zappajs') listenPort, ->
    @configure =>
      @use 'bodyParser', 'methodOverride', @app.router, 'static'
      @set 'basepath': '/v1.0'

    @configure
      development: => @use errorHandler: {dumpExceptions: on, showStack: on}
      production: => @use 'errorHandler'

    @enable 'serve jquery', 'minify'

    @include './lib/bolt'

