(function() {
  var __indexOf = Array.prototype.indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

  this.include = function() {
    var agent;
    agent = this.settings.agent;
    this.head({
      '/clients': function() {
        var checksum;
        checksum = agent.clients.checksum();
        agent.log("checksum: " + checksum);
        this.res.set('Content-MD5', checksum);
        return this.send('');
      }
    });
    this.get({
      '/clients': function() {
        return this.send(agent.clients.list());
      }
    });
    this.get({
      '/clients/:id': function() {
        var match;
        match = agent.clients.get(this.params.id);
        if (match != null) {
          return this.send(match);
        } else {
          return this.send(404);
        }
      }
    });
    return this.all({
      '/proxy/:id@:port/*': function() {
        var bolt, port;
        bolt = agent.clients.entries[this.params.id];
        port = Number(this.params.port);
        if ((bolt != null) && (bolt.relay != null) && __indexOf.call(bolt.capability, port) >= 0) {
          this.req.target = port;
          this.req.url = this.params[0];
          return bolt.relay(this.req, this.body, this.res);
        } else {
          return this.send(404);
        }
      }
    });
  };

}).call(this);
