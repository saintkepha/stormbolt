
module.exports.readBoltJson = readBoltJson = ->
    fileops = require("fileops")
    boltContent = fileops.readFileSync "./bolt.json"           
    boltJsonObj = JSON.parse boltContent            
    return boltJsonObj


