cloudflash-bolt
===============

A simple and light-weight secure tunneling application (over SSL) for
performing HTTP transactions between systems.

*cloudflash-bolt* operates via a configuration file and can act as a
 server, a client to one or more server endpoints, or both at the same
 time.

Every *cloudflash-bolt* instance can be configured to run a web server
port which effectively enables any application (local or remote) to
communicate to the *cloudflash-bolt* web service and transmit a HTTP
request via the bolt instance to any other bolt instances that have
secure tunnel established as well as any web applications locally
running on the remote bolt instances.

A simple example below:

[application A] -> [bolt 1] -> (SSL tunnel) -> [bolt 2] ->
[application B]

All HTTP transaction request is forwarded/relayed to the appropriate
destination based on a simple HTTP Header included in every reqeust
and is resolved based on CNAME field of the SSL certificate on a given
bolt instance:

cloudflash-bolt-target: "some_cname_of_bolt:port"

Going back to the simple example above, in order for *application A*
to communicate with *application B*, the *application A* would send
a HTTP request which appends an extra HTTP Header to denote the
*cloudflash-bolt-target* to be the cname of *bolt 2* along with the
port number that *application B* is listening on.

And that's it.  If *application B* wanted to talk to *application A*,
then it would do the same except it would have the cname of *bolt 1*
along with port number that *application A* is listening on as the
appropriate target header.

Unlike many other SSL proxy/tunneling applications out there, whether
*bolt 1* instance was a client to *bolt 2* or the other way around
does not make any difference to the actual *applications* that wants
to communicate with each other, who is the initiator of the request or
acting to respond to requests.

communication establishment sequence
------------------------------------

Bolt server functionality:
1.tls/ssl server will be listening for cloudflash-bolt connections on
port configured (bolt.json) port.
2.After receiving connection request from bolt client, cert check
happens and a new socket has been created for secure channel
communication. 
3.Bolt Server Maintains list of all connected clients in db.
4.Bolt Server receives requests from controller and based on header
data, Cloudflash_Bolt_Target it propagets request to corresponding
bolt client.


Bolt client functionality:
1.Initiates ssl connection request with bolt server.
2.Establish secure channel over socket with controller on configured
port.
3.Send CNAME and localforwardingports data to bolt server for
persistence.
4.Forwards HTTP requests coming on to the configured webservices
(cloudflash,salt etc) and send response back to bolt server.

List of Bolt Server APIs*
========================
url = any request path to bolt client like /modules in case of cloudflash.

<table>
  <tr>
    <th>Verb</th><th>URI</th><th>Description</th>
  </tr>
  <tr>
    <td>POST</td><td>/{url}</td><td>To configure cloudflash/salt bolt client from bolt server. </td>
  </tr>
  <tr>
    <td>GET</td><td>/{url}</td><td>get list config cloudflash/salt bolt client from bolt server.</td>
  </tr>
  <tr>
    <td>PUT</td><td>/{url}</td><td>To update config cloudflash/salt bolt client from bolt server.</td>
  </tr>
  <tr>
    <td>DELETE</td><td>/{url}</td><td>To delete config cloudflash/salt bolt client from bolt server.</td>
  </tr>
</table>


Configure VCG
-------------

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
