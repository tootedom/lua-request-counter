<!-- TOC -->

- [Name](#name)
- [Status](#status)
- [Synopsis](#synopsis)
- [Pre Requistes](#pre-requistes)
- [Description](#description)
- [Quick Example](#quick-example)
    - [Init and Access block](#init-and-access-block)
    - [Access Block](#access-block)
    - [API Specification](#api-specification)
        - [Require the library](#require-the-library)
- [Local Testing](#local-testing)
- [See Also](#see-also)

<!-- /TOC -->


# Name

Request Per Minute Counter

----

# Status

In Development

----

# Synopsis

Counts the number of requests per mintue that are occuring for nginx.
It records the last 3 minutes worth of number of requests, and the average milliseconds per request (yup averages are terrible - but have a use in places).


----

# Pre Requistes

- Nginx that can use Lua.  For example [Openresty](https://github.com/openresty/)
-- Needs the nginx lua development kit: [lua-nginx-module](https://github.com/openresty/lua-nginx-module)

- The Lua resty core library for shared dict expiry: [lua resty core](https://github.com/openresty/lua-resty-core).

- The cjson library: [lua-cjson](https://github.com/openresty/lua-cjson)

----

# Description

This module is intend for use in the `log_by_lua_block` of nginx.

It will record the number of requests that are occurring per minute for the nginx.

It will store in a [shared dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict), 3 items: 

- average latency in millis
- number of requests
- the minute period

```
      "latency_ms": 0,
      "startofminute_epoch": 1537628160,
      "requests": 0
```

# Quick Example

There's a couple of ways to set up the rate limiting:

- A combination of `init_by_lua_block` and `access_by_lua_block`
- Entirely the `access_by_lua_block`

Which is entirely up to you.  For either, you need to set up the `lua_shared_dict` in the `http` regardless.


## Init and Access block

Inside the http block, set up the `init_by_lua_block` and the shared dict
```
http {
    ...
    lua_shared_dict ratelimit_circuit_breaker 10m;

    init_by_lua_block {
        local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
        local red = { host = "127.0.0.1", port = 6379, timeout = 100}
        login, err = ratelimit.new("login", "100r/s", red)

        if not login then
            error("failed to instantiate a resty.greencheek.redis.ratelimiter.limiter object")
        end
    }

    include /etc/nginx/conf.d/*.conf;
}
```

Inside a `server` in one of the `/etc/nginx/conf.d/*.conf` includes, use the rate limit in a location or location blocks:

```
server {
    ....

    location /login {

        access_by_lua_block {
            if login:is_rate_limited(ngx.var.remote_addr) then
                return ngx.exit(429)
            end
        }

        #
        # return 200 "ok"; will not work, return in nginx does not run any of the access phases.  It just returns
        #
        content_by_lua_block {
             ngx.say('Hello,world!')
        }
    }
}
```

## Access Block


Inside the http block, set up thethe shared dict
```
http {
    ...
    lua_shared_dict ratelimit_circuit_breaker 10m;

    ...

    include /etc/nginx/conf.d/*.conf;

}
```


Inside a `server` in one of the `/etc/nginx/conf.d/*.conf` includes:
```
    location /login {
        access_by_lua_block {

            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local red = { host = "127.0.0.1", port = 6379, timeout = 100}
            local lim, err = ratelimit.new("login", "100r/s", red)

            if not lim then
                ngx.log(ngx.ERR,
                        "failed to instantiate a resty.greencheek.redis.ratelimiter.limiter object: ", err)
                return ngx.exit(500)
            end

            local is_rate_limited = lim:is_rate_limited(ngx.var.remote_addr)

            if is_rate_limited then
                return ngx.exit(429)
            end

        }

        content_by_lua_block {
             ngx.say('Hello,world!')
        }
    }
```

----

## API Specification

To use the rate `limiter` there's 3 steps:

- Import the module (`require`)
- Create a rate limiting object, by a zone
- Use the object to ratelimit based on a request parameter (remote addess, server name, etc)

### Require the library

To use any ratelimiter, you need the [resty redis library](https://github.com/openresty/lua-resty-redis).

```
local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
```

----

# Local Testing

There's a `Dockerfile` that can be used to build a local docker image for testing.  Build the image:

```
docker build --no-cache .
```

And then run from the root of the repo:


```
docker run --name ratelimiter --rm -it \
-v $(pwd)/conf.d:/etc/nginx/conf.d \
-v $(pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf \
-v $(pwd):/data \
-v $(pwd)/lib/resty/greencheek/redis/ratelimiter/limiter.lua:/usr/local/openresty/lualib/resty/greencheek/redis/ratelimiter/limiter.lua \
ratelimiter:latest /bin/bash
```

when in the contain run the `/data/init.sh` to start openresty and a local redis.  OpenResty will be running on port `9090`.
Gil Tene's fork of [wrk](https://github.com/giltene/wrk2) is also complied during the build of the docker image.

```
/data/init.sh
curl localhost:9090/login
wrk -t1 -c1 -d30s -R2 http://localhost:9090/login
```

There is a `nginx.config` and a `conf.d/default.config` example in the project for you to work with.  By default there are 3 locations:

/t
/login
/login_foreground

----

# See Also

* Rate Limiting with NGINX: https://www.nginx.com/blog/rate-limiting-nginx/
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
