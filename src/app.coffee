###
argv = require('optimist')
    .usage('Start stormbolt with a configuration file.\nUsage: $0')
    .demand('f')
    .default('f','/etc/stormstack/stormbolt.json')
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
###
stormbolt = require './bolt'

bolt = new stormbolt 
bolt.run (res) ->
    if res instanceof Error
        console.log 'error: ' + res
