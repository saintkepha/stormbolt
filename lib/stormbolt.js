(function() {
  var BoltRegistry, BoltStream, StormAgent, StormBolt, StormData, StormRegistry, agent, config, storm,
    __hasProp = Object.prototype.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor; child.__super__ = parent.prototype; return child; },
    __indexOf = Array.prototype.indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

  StormAgent = require('stormagent');

  StormData = StormAgent.StormData;

  BoltStream = (function(_super) {
    var MuxDemux, async;

    __extends(BoltStream, _super);

    async = require('async');

    MuxDemux = require('mux-demux');

    function BoltStream(id, stream) {
      var cstream,
        _this = this;
      this.id = id;
      this.stream = stream;
      this.ready = false;
      this.capability = [];
      this.monitoring = false;
      this.stream.pipe(this.mux = MuxDemux()).pipe(this.stream);
      cstream = this.mux.createReadStream('capability');
      cstream.on('data', function(capa) {
        _this.log("received capability info from peer: " + capa);
        _this.capability = capa.split(',').map(function(entry) {
          return Number(entry);
        });
        _this.emit('capability', capa);
        if (!_this.ready) {
          _this.ready = true;
          return _this.emit('ready');
        }
      });
      this.stream.on('close', function() {
        _this.log("bolt stream closed for " + _this.id);
        _this.destroy();
        return _this.emit('close');
      });
      this.stream.on('error', function(err) {
        _this.log("issue with underlying bolt stream...", err);
        _this.destroy();
        return _this.emit('error', err);
      });
      this.mux.on('error', function(err) {
        _this.log("issue with bolt mux channel...", err);
        _this.destroy();
        return _this.emit('error', err);
      });
      BoltStream.__super__.constructor.call(this, this.id, {
        cname: this.id,
        remote: this.stream.remoteAddress
      });
    }

    BoltStream.prototype.monitor = function(interval, period) {
      var bstream, validity,
        _this = this;
      if (this.monitoring) return;
      this.monitoring = true;
      validity = period;
      bstream = this.mux.createStream('beacon', {
        allowHalfOpen: true
      });
      bstream.on('data', function(beacon) {
        _this.log("monitor - received beacon from client: " + _this.id);
        bstream.write("beacon:reply");
        _this.emit('beacon', beacon);
        return validity = period;
      });
      return async.whilst(function() {
        return validity > 0 && _this.monitoring && _this.ready;
      }, function(repeat) {
        validity -= interval / 1000;
        _this.log("monitor - " + _this.id + " has validity=" + validity);
        return setTimeout(repeat, interval);
      }, function(err) {
        _this.log("monitor - " + _this.id + " has expired and being destroyed...");
        _this.destroy();
        _this.emit('expired');
        return _this.monitoring = false;
      });
    };

    BoltStream.prototype.relay = function(request, response) {
      var relay, reply, url, _ref,
        _this = this;
      if (!this.ready) throw new Error("cannot relay to unready boltstream...");
      try {
        this.log("relay - forwarding request to " + this.id + " at " + this.stream.remoteAddress + " for " + request.url);
        if (_ref = request.target, __indexOf.call(this.capability, _ref) < 0) {
          throw new Error("unable to forward request to " + this.id + " for unsupported port: " + request.target);
        }
        relay = this.mux.createStream("relay:" + request.target, {
          allowHalfOpen: true
        });
        if (!request.url) {
          this.log("no request.url is set!");
          request.url = '/';
        }
        if (typeof request.url === 'string') {
          url = require('url').parse(request.url);
          if (!/^\//.test(url.pathname)) url.pathname = '/' + url.pathname;
          if (!/^\//.test(url.pathname)) url.path = '/' + url.path;
          request.url = require('url').format(url);
        }
        relay.write(JSON.stringify({
          method: request.method,
          url: request.url,
          port: request.port,
          data: request.data
        }));
        request.on('error', function(err) {
          _this.log("error relaying request via boltstream...", err);
          return relay.destroy();
        });
        relay.on('error', function(err) {
          return this.log("error during relay multiplexing boltstream...", err);
        });
        relay.end();
        reply = {
          header: null,
          body: ''
        };
        relay.on('data', function(chunk) {
          try {
            if (!reply.header) {
              reply.header = JSON.parse(chunk);
              if ((response != null) && (response.writeHead != null)) {
                response.writeHead(reply.header.statusCode, reply.header.headers);
                return relay.pipe(response);
              }
            } else {
              if (response == null) return reply.body += chunk;
            }
          } catch (err) {
            _this.log("invalid relay response received from " + _this.id + ":", err);
            return relay.end();
          }
        });
        relay.on('end', function() {
          return relay.emit('reply', reply);
        });
        return relay;
      } catch (err) {
        return this.log("error duing relaying request to boltstream", err);
      }
    };

    BoltStream.prototype.destroy = function() {
      try {
        this.ready = this.monitoring = false;
        this.mux.destroy();
        return this.stream.destroy();
      } catch (err) {
        return this.log("unable to properly terminate bolt stream: " + this.id, err);
      }
    };

    return BoltStream;

  })(StormData);

  StormRegistry = StormAgent.StormRegistry;

  BoltRegistry = (function(_super) {

    __extends(BoltRegistry, _super);

    function BoltRegistry(filename) {
      this.on('removed', function(bolt) {
        if (bolt != null) return bolt.destroy();
      });
      BoltRegistry.__super__.constructor.call(this, filename);
    }

    BoltRegistry.prototype.get = function(key) {
      var entry;
      entry = BoltRegistry.__super__.get.call(this, key);
      if (entry == null) return;
      return {
        cname: key,
        ports: entry.capability,
        address: entry.data != null ? entry.data.remote : void 0,
        validity: entry.validity
      };
    };

    return BoltRegistry;

  })(StormRegistry);

  StormBolt = (function(_super) {
    var MuxDemux, async, extend, fs, http, schema, tls, url, validate;

    __extends(StormBolt, _super);

    validate = require('json-schema').validate;

    tls = require("tls");

    fs = require("fs");

    http = require("http");

    url = require('url');

    MuxDemux = require('mux-demux');

    async = require('async');

    extend = require('util')._extend;

    schema = {
      name: "storm",
      type: "object",
      additionalProperties: true,
      properties: {
        cert: {
          type: "any",
          required: true
        },
        key: {
          type: "any",
          required: true
        },
        ca: {
          type: "any",
          required: true
        },
        uplinks: {
          type: "array"
        },
        uplinkStrategy: {
          type: "string"
        },
        allowRelay: {
          type: "boolean"
        },
        relayPort: {
          type: "integer"
        },
        allowedPorts: {
          type: "array"
        },
        listenPort: {
          type: "integer"
        },
        beaconValidity: {
          type: "integer"
        },
        beaconInterval: {
          type: "integer"
        },
        beaconRetry: {
          type: "integer"
        }
      }
    };

    function StormBolt(config) {
      StormBolt.__super__.constructor.call(this, config);
      this["import"](module);
      this.repeatInterval = 5;
      this.clients = new BoltRegistry;
      if (this.config.insecure) process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    }

    StormBolt.prototype.status = function() {
      var state, _ref;
      state = StormBolt.__super__.status.apply(this, arguments);
      state.uplink = (_ref = this.uplink) != null ? _ref : null;
      state.clients = this.clients.list();
      return state;
    };

    StormBolt.prototype.run = function(config) {
      var ca, cacert, chain, connected, i, line, retries, selfconfig, server, storm, _i, _len, _ref,
        _this = this;
      StormBolt.__super__.run.call(this, config, schema);
      try {
        this.log('run - validating security credentials...');
        if (!(this.config.cert instanceof Buffer)) {
          this.config.cert = fs.readFileSync("" + this.config.cert, 'utf8');
        }
        if (!(this.config.key instanceof Buffer)) {
          this.config.key = fs.readFileSync("" + this.config.key, 'utf8');
        }
        if (!(this.config.ca instanceof Buffer)) {
          ca = [];
          chain = fs.readFileSync("" + this.config.ca, 'utf8');
          chain = chain.split("\n");
          cacert = [];
          for (_i = 0, _len = chain.length; _i < _len; _i++) {
            line = chain[_i];
            if (!(line.length !== 0)) continue;
            cacert.push(line);
            if (line.match(/-END CERTIFICATE-/)) {
              ca.push(cacert.join("\n"));
              cacert = [];
            }
          }
          this.config.ca = ca;
        }
      } catch (err) {
        this.log("run - missing proper security credentials, attempting to self-configure...");
        storm = null;
        /* uncomment during dev/testing
        storm =
            tracker: "https://stormtracker.dev.intercloud.net"
            skey: "some-serial-number"
            token:"some-valid-token"
        */
        selfconfig = function() {
          return _this.activate(storm, function(storm) {
            return _this.run(storm.bolt);
          });
        };
        if (this.state.activated) {
          this.state.activated = false;
          this.log("previous activation attempt failed... retrying in 60 seconds");
          setTimeout(selfconfig, 60000);
        } else {
          selfconfig();
        }
        return;
      }
      this.once("error", function(err) {
        return _this.log("run - bolt fizzled... should do something smart here");
      });
      if ((this.config.listenPort != null) && this.config.listenPort > 0) {
        server = this.listen(this.config.listenPort, {
          key: this.config.key,
          cert: this.config.cert,
          ca: this.config.ca,
          requestCert: true,
          rejectUnauthorized: true
        }, function(bolt) {
          return bolt.once('ready', function() {
            bolt.monitor(_this.config.repeatdelay, _this.config.beaconValidity);
            _this.clients.add(bolt.id, bolt);
            bolt.on('close', function(err) {
              _this.log("bolt.close on " + bolt.id + ":", err);
              return _this.clients.remove(bolt.id);
            });
            return bolt.on('error', function(err) {
              _this.log("bolt.error on " + bolt.id + ":", err);
              return _this.clients.remove(bolt.id);
            });
          });
        });
        server.on('error', function(err) {
          _this.log("fatal issue with bolt server: " + err);
          _this.clients.running = false;
          return _this.emit('server.error', err);
        });
      }
      if ((this.config.uplinks != null) && this.config.uplinks.length > 0) {
        _ref = [0, 0], i = _ref[0], retries = _ref[1];
        connected = false;
        this.on('client.connection', function(stream) {
          connected = true;
          return retries = 0;
        });
        this.on('client.disconnect', function(stream) {
          return connected = false;
        });
        async.forever(function(next) {
          if (retries > 30) {
            next(new Error("retry max exceeded, unable to establish bolt server connection"));
          }
          return async.until(function() {
            return connected;
          }, function(repeat) {
            var host, port, uplink, _ref2;
            uplink = _this.config.uplinks[i++];
            _ref2 = uplink.split(':'), host = _ref2[0], port = _ref2[1];
            if (port == null) port = 443;
            _this.connect(host, port, {
              key: _this.config.key,
              cert: _this.config.cert,
              ca: _this.config.ca,
              requestCert: true
            });
            if (!(i < _this.config.uplinks.length)) i = 0;
            return setTimeout(repeat, 5000);
          }, function(err) {
            return setTimeout(next, 5000);
          });
        }, function(err) {
          if (err != null) return _this.emit('error', err);
        });
      }
      if (this.config.allowRelay) return this.proxy(this.config.relayPort);
    };

    StormBolt.prototype.proxy = function(port) {
      var acceptor,
        _this = this;
      if (!((port != null) && port > 0)) {
        this.log("need to pass in valid port for performing relay");
        return;
      }
      this.log('starting the proxy relay on port ' + port);
      acceptor = http.createServer().listen(port);
      return acceptor.on("request", function(request, response) {
        var cname, entry, error, target, _ref;
        target = request.headers['stormbolt-target'];
        if (target) _ref = target.split(':'), cname = _ref[0], port = _ref[1];
        entry = _this.clients.entries[cname];
        if (!(entry && __indexOf.call(entry.capability, port) >= 0)) {
          error = "stormfbolt-target [" + target + "] cannot be reached!";
          _this.log("error:", error);
          response.writeHead(404, {
            'Content-Length': error.length,
            'Content-Type': 'application/json',
            'Connection': 'close'
          });
          response.end(error, "utf8");
          return;
        }
        _this.log("[proxy] forwarding request to " + cname + " " + entry.stream.remoteAddress);
        request.target = port;
        return entry.relay(request, response);
      });
    };

    StormBolt.prototype.listen = function(port, options, callback) {
      var server,
        _this = this;
      this.log("server port:" + port);
      server = tls.createServer(options, function(stream) {
        var certObj, cname, _ref;
        try {
          _this.log("TLS connection established with VCG client from: " + stream.remoteAddress);
          certObj = stream.getPeerCertificate();
          cname = certObj.subject.CN;
          _this.log((_ref = ("server connected from " + cname + ": ") + stream.authorized) != null ? _ref : 'unauthorized');
          if (callback != null) return callback(new BoltStream(cname, stream));
        } catch (error) {
          _this.log('unable to retrieve peer certificate and authorize connection!', error);
          return stream.end();
        }
      });
      server.on('clientError', function(exception) {
        return _this.log('TLS handshake error:', exception);
      });
      server.on('error', function(err) {
        var message;
        _this.log('TLS server connection error :' + err.message);
        try {
          message = String(err.message);
          if ((message.indexOf('ECONNRESET')) >= 0) {
            _this.log('throw error: ' + 'ECONNRESET');
            throw new Error(err);
          }
        } catch (e) {
          return _this.log('error e' + e);
        }
      });
      server.listen(port);
      return server;
    };

    StormBolt.prototype.connect = function(host, port, options, callback) {
      var calledReconnectOnce, stream,
        _this = this;
      tls.SLAB_BUFFER_SIZE = 100 * 1024;
      this.log("making connection to bolt server at: " + host + ':' + port);
      calledReconnectOnce = false;
      stream = tls.connect(port, host, options, function() {
        var forwardingPorts, mx;
        _this.uplink = {
          host: host,
          port: port
        };
        if (stream.authorized) {
          _this.log("Successfully connected to bolt server");
        } else {
          _this.log("Failed to authorize TLS connection. Could not connect to bolt server (ignored for now)");
        }
        _this.emit('client.connection', stream);
        if (callback != null) callback(stream);
        stream.setKeepAlive(true, 60 * 1000);
        stream.setEncoding('utf8');
        stream.pipe(mx = MuxDemux()).pipe(stream);
        forwardingPorts = _this.config.allowedPorts;
        mx.on("error", function(err) {
          _this.log("MUX ERROR:", err);
          mx.destroy();
          stream.destroy();
          return _this.emit('client.disconnect', stream);
        });
        return mx.on("connection", function(_stream) {
          var action, breply, bsent, incoming, request, target, _ref, _ref2;
          _ref = _stream.meta.split(':'), action = _ref[0], target = _ref[1];
          _this.log("Client: action " + action + "  target " + target);
          _stream.on('error', function(err) {
            return _this.log(("Client: mux stream for " + _stream.meta + " has error: ") + err);
          });
          switch (action) {
            case 'capability':
              _this.log('sending capability information...');
              _stream.write(forwardingPorts.join(','));
              return _stream.end();
            case 'beacon':
              _ref2 = [0, 0], bsent = _ref2[0], breply = _ref2[1];
              _stream.on('data', function(data) {
                breply++;
                return _this.log("received beacon reply: " + data);
              });
              _this.log('sending beacons...');
              return async.whilst(function() {
                return bsent - breply < _this.config.beaconRetry;
              }, function(repeat) {
                _this.log("sending beacon...");
                _stream.write("Beacon");
                bsent++;
                return _this.beaconTimer = setTimeout(repeat, _this.config.beaconInterval * 1000);
              }, function(err) {
                if (err == null) {
                  err = "beacon retry timeout, server no longer responding";
                }
                _this.log("final call on sending beacons, exiting with: " + (err != null ? err : "no errors"));
                try {
                  _stream.end();
                  mx.destroy();
                  return stream.end();
                } catch (err) {
                  return _this.log("error during client connection shutdown due to beacon timeout: " + err);
                }
              });
            case 'relay':
              target = Number(target);
              if (__indexOf.call(forwardingPorts, target) < 0) {
                _this.log("request for relay to unsupported target port: " + target);
                _stream.end();
                break;
              }
              incoming = '';
              request = null;
              _stream.on('data', function(chunk) {
                if (!request) {
                  try {
                    _this.log("request received: " + chunk);
                    return request = JSON.parse(chunk);
                  } catch (err) {
                    _this.log("invalid relay request!");
                    return _stream.end();
                  }
                } else {
                  _this.log("received some data: " + chunk);
                  return incoming += chunk;
                }
              });
              return _stream.on('end', function() {
                var relay, roptions, timeout;
                _this.log("relaying following request to localhost:" + target + " - ", request);
                if (typeof request.url === 'object') {
                  roptions = url.format(request.url);
                } else {
                  roptions = url.parse(request.url);
                }
                roptions.method = request.method;
                roptions.headers = {
                  'Content-Type': 'application/json'
                };
                roptions.agent = false;
                if (roptions.port == null) roptions.port = target;
                _this.log(JSON.stringify(roptions));
                timeout = false;
                relay = http.request(roptions, function(reply) {
                  if (!timeout) {
                    _this.log("sending back reply");
                    reply.setEncoding('utf8');
                    try {
                      _stream.write(JSON.stringify({
                        statusCode: reply.statusCode,
                        headers: reply.headers
                      }));
                      return reply.pipe(_stream, {
                        end: true
                      });
                    } catch (err) {
                      return _this.log("unable to write response back to requestor upstream bolt! error: " + err);
                    }
                  }
                });
                if (request.data != null) {
                  relay.write(JSON.stringify(request.data));
                }
                relay.end();
                relay.on('end', function() {
                  return _this.log("no more data");
                });
                relay.setTimeout(20000, function() {
                  _this.log("error during performing relay action! request timedout.");
                  timeout = true;
                  try {
                    _stream.write(JSON.stringify({
                      statusCode: 408,
                      headers: null
                    }));
                    _stream.end();
                  } catch (err) {
                    _this.log("unable to write response code back to requestor upstream bolt! error: " + err);
                  }
                  return _this.log("[relay request timed out, sending 408]");
                });
                return relay.on('error', function(err) {
                  _this.log("[relay request failed with following error]");
                  _this.log(err);
                  try {
                    _stream.write(JSON.stringify({
                      statusCode: 500,
                      headers: null
                    }));
                    _stream.end();
                  } catch (err) {
                    _this.log("unable to write response code back to requestor upstream bolt! error: " + err);
                  }
                  return _this.log("[relay request error, sending 500]");
                });
              });
            default:
              _this.log("unsupported action/target supplied by mux connection: " + action + "/" + target);
              return _stream.end();
          }
        });
      });
      stream.on("error", function(err) {
        clearTimeout(_this.beaconTimer);
        _this.log(("client error during connection to " + host + ":" + port + " with: ") + err);
        return _this.emit('client.disconnect', stream);
      });
      stream.on("close", function() {
        clearTimeout(_this.beaconTimer);
        _this.log("client closed connection to: " + host + ":" + port);
        return _this.emit('client.disconnect', stream);
      });
      return stream;
    };

    return StormBolt;

  })(StormAgent);

  module.exports = StormBolt;

  if (require.main === module) {
    /*
        argv = require('minimist')(process.argv.slice(2))
        if argv.h?
            console.log """
                -h view this help
                -p port number
                -l logfile
                -d datadir
            """
            return
    
        config = {}
        config.port    = argv.p ? 5000
        config.logfile = argv.l ? "/var/log/stormbolt.log"
        config.datadir = argv.d ? "/var/stormstack"
    */
    config = null;
    storm = null;
    agent = new StormBolt(config);
    agent.run(storm);
    if (typeof gc !== "undefined" && gc !== null) {
      setInterval((function() {
        return gc();
      }), 60000);
    }
  }

}).call(this);
