stormbolt
===============

A simple and light-weight secure tunneling application (over SSL) for
performing HTTP transactions between systems.

*stormbolt* operates via a configuration file and can act as a
 server, a client to one or more server endpoints, or both at the same
 time.

Every *stormbolt* instance can be configured to run a web server
port which effectively enables any application (local or remote) to
communicate to the *stormbolt* web service and transmit a HTTP
request via the bolt instance to any other bolt instances that have
secure tunnel established as well as any web applications locally
running on the remote bolt instances.

A simple example below:

[application A] -> [stormbolt 1] -> (SSL tunnel) -> [stormbolt 2] ->
[application B]

All HTTP transaction request is forwarded/relayed to the appropriate
destination based on a simple HTTP Header included in every reqeust
and is resolved based on CNAME field of the SSL certificate on a given
bolt instance:

URL: "/proxy/cname_of_bolt@port"

Going back to the simple example above, in order for *application A*
to communicate with *application B*, the *application A* would send
a HTTP request which mentions HTTP url to denote the prefix path as
*/proxy/:id@:port/* with the cname of the *bolt 2* along with the
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
1.tls/ssl server will be listening for stormbolt connections on
port configured (listenPort field in package.json).
2.After receiving connection request from bolt client, cert check
happens and a new socket has been created for secure channel
communication. 
3.Bolt Server Maintains list of all connected clients in db.
4.Bolt Server receives requests from parent application and based on
url target path, it propagets the request to the corresponding
bolt client.


Bolt client functionality:
1.Initiates ssl connection request with bolt server.
2.Establish secure channel over socket with controller on configured
port.
3.Send CNAME, ip address and port details to bolt server for persistence.
4.Forwards HTTP requests coming on to the configured webservices
(stormtower, stormlight etc.) and send response back to bolt server.

*List of StormBolt APIs*
=========================

<table>
  <tr>
    <th>Verb</th><th>URI</th><th>Description</th>
  </tr>
  <tr>
    <td>HEAD</td><td>/clients</td><td>global md5 checksum of all stormbolt client's response object</td>
  </tr>
  <tr>
    <td>GET</td><td>/clients</td><td>get list of all stormbolt clients connected to the stormbolt server</td>
  </tr>
  <tr>
    <td>GET</td><td>/clients/:id</td><td>get details of the given stormbolt client</td>
  </tr>
  <tr>
    <td>GET</td><td>/proxy/:id@:port</td><td>forwards the request to given stormbolt client's specific port</td>
  </tr>
  <tr>
    <td>POST</td><td>/proxy/:id@:port</td><td>forwards the request to given stormbolt client's specific port</td>
  </tr>
  <tr>
    <td>PUT</td><td>/proxy/:id@:port</td><td>forwards the request to given stormbolt client's specific port</td>
  </tr>
  <tr>
    <td>DELETE</td><td>/proxy/:id@:port</td><td>forwards the request to given stormbolt client's specific port</td>
  </tr>
</table>


Get global md5 checksum
------------------------

    Verb   URI               Description
    HEAD   /clients          get global md5 checksum of all stormbolt client

On success it returns the global md5 checksum string in the Content-MD5 header field. This MD5 checksum string is generated from the response object of all stormbolt clients connected to stormbolt server.

### Response Header

    HTTP/1.1 200 OK
    X-Powered-By: Zappa 0.4.22
    Content-MD5: f0c62fc2b2ab43ee5954280acbea75ad
    Content-Type: text/html; charset=utf-8
    Content-Length: 0
    Date: Thu, 10 Jul 2014 09:32:12 GMT
    Connection: keep-alive


Get list of connected stormbolt clients
----------------------------------------

    Verb   URI               Description
    GET    /clients          get list of all stormbolt clients connected to the stormbolt server

On success it returns the list of all stormbolt clients connected to the server. This includes details like uuid, port and ip address of each client.

### Response

    [
      {
        "cname": "5b861151-5e17-4c24-b0f4-d2f77940fe1b",
        "ports": [
          5000
        ],
        "address": "67.229.243.47"
      },
      {
        "cname": "e2413de6-8080-415b-a475-f987d3d7be8a",
        "ports": [
          5000
        ],
        "address": "67.229.243.48"
      }
    ]


Get ip and port details of specific stormbolt
----------------------------------------------

    Verb   URI               Description
    GET   /clients/:id       get details of the given stormbolt client

On success it provides information such as uuid, ports and ip address about given stormbolt client.

### Request URL

GET  /clients/5b861151-5e17-4c24-b0f4-d2f77940fe1b

### Response

    {
      "cname": "5b861151-5e17-4c24-b0f4-d2f77940fe1b",
      "ports": [
        5000
      ],
      "address": "67.229.243.47"
    }


Common endpoint for GET/POST/PUT/DELETE calls on specific stormbolt
--------------------------------------------------------------------

    Verb   URI                  Description
    GET   /proxy/:id@:port/*    forwards the GET API call to given endpoint of specific stormbolt

This provides a common endpoint for all RESTful calls GET/POST/PUT/DELETE to be forwarded to specific stormbolt client. The :id is the uuid of the stormbolt client and :port specifies on which port the request will be forwarded to. Actual endpoint of the target stormbolt client is mentioned at the end. The output is then send back from bolt client.

### Request URL

GET  /proxy/5b861151-5e17-4c24-b0f4-d2f77940fe1b@5000/environment

### Response

    {
      "tmpdir": "/lib/node_modules/stormflash",
      "endianness": "LE",
      "hostname": "kvm570",
      "type": "Linux",
      "platform": "linux",
      "release": "2.6.34.7",
      "arch": "ia32",
      "uptime": 73137.129523876,
      "loadavg": [
        0.14697265625,
        0.0322265625,
        0.01025390625
      ],
      "totalmem": 18446744073709548000,
      "freemem": 18446744073709548000,
      "cpus": [
        {
          "model": "Intel(R) Core(TM)2 Duo CPU T7700 @ 2.40GHz",
          "speed": 1999,
          "times": {
            "user": 11155500,
            "nice": 0,
            "sys": 2555200,
            "idle": 717336700,
            "irq": 0
          }
        }
      ],
      "networkInterfaces": {
        "lo": [
          {
            "address": "127.0.0.1",
            "family": "IPv4",
            "internal": true
          }
        ],
        "wan0": [
          {
            "address": "10.101.1.20",
            "family": "IPv4",
            "internal": false
          }
        ]
      }
    }


