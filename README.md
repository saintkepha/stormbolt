cloudflash-bolt
===============
Cloudflash secure tunnel module for connection to Cloudflash Controller

Cloudflash-bolt is a generic application which contains Bolt Server and Bolt Client modules.
Bolt Server and client will coommunicate over ssl secure channel.

Bolt server functionality:
1.tls/ssl server will be listening for cloudflash-bolt connections on port configured(bolt.json) port.
2.After receiving connection request from bolt client, cert check happens and a new socket has been created for secure channel communication. 
3.Bolt Server Maintains list of all connected clients in db.
4.Bolt Server receives requests from controller and based on header data, Cloudflash_Bolt_Target it propagets request to corresponding bolt client.


Bolt client functionality:
1.Initiates ssl connection request with bolt server.
2.Establish secure channel over socket with controller on configured port.
3.Send CNAME and localforwardingports data to bolt server for persistence.
4.Forwards HTTP requests coming on to the configured webservices (cloudflash,salt etc) and send response back to bolt server.

List of Bolt Server APIs*
========================
url = any request path to bolt client like /modules in case of cloudflash.

<table>
  <tr>
    <th>Verb</th><th>URI</th><th>Description</th>
  </tr>
  <tr>
    <td>POST</td><td>/{url}</td><td>To configure cloudflash with config requests</td>
  </tr>
  <tr>
    <td>GET</td><td>/{url}</td><td>get list of bolt clients managed by the bolt server</td>
  </tr>
  <tr>
    <td>PUT</td><td>/{url}</td><td>To configure cloudflash with config requests</td>
  </tr>
  <tr>
    <td>DELETE</td><td>/{url}</td><td>get list of bolt clients managed by the bolt server</td>
  </tr>
</table>



Configure VCG
-------------------------

    Verb          URI                     Description
    POST        /modules             To configure cloudflash with config requests

## Request JSON For all config posts on VCG (cloudflash)
    Request
    {
        "name": "cloudflash-openvpn",
        "version": "0.1.6"
    }
	
### Request JSON  - To configure /modules endpoint on VCG

    {
    "id": "b2cc1a38-4beb-4792-8b01-afd622d056e6",
    "description": {
        "name": "cloudflash-openvpn",
        "version": "0.1.6"
    },
    "status": {
        "installed": true
    }
    }
