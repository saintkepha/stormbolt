
module.exports.readBoltJson = readBoltJson = ->
    fileops = require("fileops")
    filepath = "/etc/bolt/bolt.json"
    res =  fileops.fileExistsSync filepath
    unless res instanceof Error
        boltContent = fileops.readFileSync filepath           
        boltJsonObj = JSON.parse boltContent            
        return boltJsonObj
    else
        return new Error "file does not exist! " + res


