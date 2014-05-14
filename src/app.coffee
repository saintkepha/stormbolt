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

cloudflashbolt = require './lib/bolt'

bolt = new cloudflashbolt config
bolt.start (res) ->
    if res instanceof Error
        console.log 'error: ' + res
