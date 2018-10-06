<!-- TOC -->

- [Name](#name)
- [Status](#status)
- [Synopsis](#synopsis)
- [Pre Requistes](#pre-requistes)
- [Description](#description)
    - [Rate in Current Time Period](#rate-in-current-time-period)
- [Quick Example](#quick-example)
- [API Specification](#api-specification)
    - [Set up a shared dict](#set-up-a-shared-dict)
        - [Shared dict size](#shared-dict-size)
    - [Recording a request as part of "all" key](#recording-a-request-as-part-of-all-key)
    - [Recording a request under a specific key and "all" key](#recording-a-request-under-a-specific-key-and-all-key)
    - [Recording a request under a specific key](#recording-a-request-under-a-specific-key)
    - [Stats Endpoint](#stats-endpoint)
        - [Single Key stats](#single-key-stats)
        - [All Request Stats Recorded for all keys](#all-request-stats-recorded-for-all-keys)
- [Local Testing](#local-testing)
- [See Also](#see-also)

<!-- /TOC -->


# Name

Request Per Minute Counter

----

# Status

Beta

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

It will record the number of requests that are occurring per minute.

It will store in a [shared dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict), 3 items:

- Accumulated latency in millis
- Number of requests in the minute period of 00s to 59s
- The minute period

The number of requests is stored as the number of requests that occurred during a minute period 00-59s.  The latency is the accumulated sum of request time for
all the requests during that minute period.

The module provides a stats endpoint that will report the number of requests, and average latency for 3 time periods:

- The current period that is active: "current"
- The previous minute period: "prev1"
- The minute period previous to the previous one: "prev2"

## Rate in Current Time Period

For the current time period it will report the "rate" of requests for a "minute" period based on a leaky bucket algorithm.

```
{
  "shared_dict_info": {
    "free_space": 4096,
    "capacity": 16384
  },
  "stats": {
    "all": {
      "current": {
        "latency_ms": 1.290454016298,
        "startofminute_epoch": 1537709460,
        "requests": 1718,
        "rate": 11532.400005341,
        "epoch": 1537709468
      },
      "prev1": {
        "latency_ms": 1.3051666666666,
        "startofminute_epoch": 1537709400,
        "requests": 12000
      },
      "prev2": {
        "latency_ms": 1.3002296211251,
        "startofminute_epoch": 1537709340,
        "requests": 3484
      }
    }
  }
}
```

The rate is based on the cloudflare rate calculation as described on this blog (I have no knowledge of the actual implementation details of the cloudflare rate limiter.
The implementation of the rate calculation in this library is soley based on the details described on the following blog):

- https://blog.cloudflare.com/counting-things-a-lot-of-different-things/

The rate approximation calculation as specified on the above blog, is as follows (where the window_period is 60s, i.e. one minute) :

```
rate = number_of_requests_in_previous_window * ((window_period - elasped_time_in_current_period) / window_period) + number_of_requests_in_current_window
```


# Quick Example

Set up the shared_dict within the `http` section of nginx:

```
http {
    ...
    lua_shared_dict request_counters 64k;
    ...
}
```

Set up a `log_by_lua_block` within a server block.

The below checks the setting of the nginx variable $request_key.
When the `request_key` is variable is set, the method `record_request` is called with the given key.
This records the number of requests that have occurred for that key, but also records that request against the `all` key.

When the `request_key` is set to `stats` the request is not logged.  This is so that the "stats" requests do not add to the
request counting and skew the `all` metric (this is enitrely up to you - this is just an example)

When the `request_key` variable is not set.

```
    log_by_lua_block {
        local request_counter = require "resty.greencheek.request.counter"
        local shdict = require "resty.core.shdict"

        local key = ngx.var.request_key
        if key ~= "stats" then
            if key == "" then
                request_counter.record_generic_request("request_counters",ngx.var.request_time)
            else
                request_counter.record_request("request_counters",key,ngx.var.request_time)
            end
        end
    }
```

Set up location blocks to the log requests into various `keys`

```
server {

    listen 9090;

    log_by_lua_block {
        local request_counter = require "resty.greencheek.request.counter"

        local key = ngx.var.request_key
        if key ~= "stats" then
            if key == "" then
                request_counter.record_generic_request("request_counters",ngx.var.request_time)
            else
                request_counter.record_request("request_counters",key,ngx.var.request_time)
            end
        end
    }

    location /log {

        content_by_lua_block {
            ngx.sleep(0.001)
            ngx.say('Hello,world!')
        }
    }

    location /key {

        set $request_key "key";
        content_by_lua_block {
            ngx.sleep(0.2)
            ngx.say('Hello,world!')
        }
    }

    location /topic {
        set $request_key "topic";
        content_by_lua_block {
            ngx.sleep(0.2)
            ngx.say('Hello,world!')
        }
    }

    location /all_only_stats {
        set $request_key "stats";

        content_by_lua_block {
            local request_counter = require "resty.greencheek.request.counter"

            ngx.say(request_counter.single_stats("request_counters","all"))
        }
    }

    location /stats {
        content_by_lua_block {
            local request_counter = require "resty.greencheek.request.counter"

            ngx.say(request_counter.stats("request_counters"))
        }
    }

}
```

----

# API Specification

To use the request counter `limiter` there's 2 steps to record the requests, 1 to show the stats:

- Create a shared dict: `lua_shared_dict request_counters 16k;`
- Set up `log_by_lua_block`
- Set up a location block to report the requests stats: `request_counter.stats()`

## Set up a shared dict

If all you are going to record is the number of request for all requests, then a shared dict of 16k is fine.

```
    lua_shared_dict request_counters 16k;
```

### Shared dict size

A shared dict of size 16k, can hold 5 different request keys.

The `stats` end point output the size of the shared dict that is remaining.  An error like the following may be encountered when the shared dict max size has been hit:

```
2018/09/23 16:15:27 [error] 149#149: *35 [lua] counter.lua:89: |{"level" : "ERROR", "msg" : "failed_set_key_expiry", "key": "topic_1537719300", "retry" : "false" }|not found, context: ngx.timer, client: 127.0.0.1, server: 0.0.0.0:9090
2018/09/23 16:15:27 [error] 149#149: *35 [lua] counter.lua:97: |{"level" : "ERROR", "msg" : "failed_set_key_expiry", "key": "topic_1537719300" }|not found, context: ngx.timer, client: 127.0.0.1, server: 0.0.0.0:9090
```

----

## Recording a request as part of "all" key

This records the request against the `all` key

syntax: request_counter.record_generic_request(dict_name,request_latency)

example: request_counter.record_generic_request("request_counters",ngx.var.request_time)

This is intended for use in a `log_by_lua_block`

```
log_by_lua_block {
    local request_counter = require "resty.greencheek.request.counter"
    request_counter.record_generic_request("request_counters",ngx.var.request_time)
}
```

----

## Recording a request under a specific key and "all" key

This records the request against only a specific key.  *note* The key should not contain the `pipe` character `|`

syntax: request_counter.record_request(dict_name,key,request_latency)

example: request_counter.record_request("request_counters","login",ngx.var.request_time)

This is intended for use in a `log_by_lua_block`

```
log_by_lua_block {
    local request_counter = require "resty.greencheek.request.counter"
    request_counter.record_request("request_counters","login",ngx.var.request_time)
}
```

----

## Recording a request under a specific key

This records the request against only a specific key.  *note* The key should not contain the `pipe` character `|`

syntax: request_counter.record_specific_request(dict_name,request_latency)

example: request_counter.record_specific_request("request_counters","login",ngx.var.request_time)

This is intended for use in a `log_by_lua_block`

```
log_by_lua_block {
    local request_counter = require "resty.greencheek.request.counter"
    request_counter.record_specific_request("request_counters","login",ngx.var.request_time)
}
```

## Stats Endpoint

There are 2 stats endpoint.  1 that outputs all the keys under which requests are being recorded,
and one that outputs only the stats for a specific key.

### Single Key stats

syntax: request_counter.single_stats(dict_name,stats_key)

example: request_counter.single_stats("request_counters","all")

The stats endpoint will usually be exposed by a specific location block:

```
    location /all_only_stats {
        set $request_key "stats";

        content_by_lua_block {
            local request_counter = require "resty.greencheek.request.counter"

            ngx.say(request_counter.single_stats("request_counters","all"))
        }
    }
```

This for example will output something similar to the following:

```
{
  "shared_dict_info": {
    "free_space": 4096,
    "capacity": 16384
  },
  "stats": {
    "current": {
      "latency_ms": 173.86666666667,
      "startofminute_epoch": 1537724100,
      "requests": 15,
      "rate": 27.094266573588
    },
    "prev1": {
      "latency_ms": 1.2950819672131,
      "startofminute_epoch": 1537724040,
      "requests": 61
    },
    "prev2": {
      "latency_ms": 0,
      "startofminute_epoch": 1537723980,
      "requests": 0
    }
  }
}
```

### All Request Stats Recorded for all keys


syntax: request_counter.stats(dict_name)

example: request_counter.stats("request_counters")

The stats endpoint will usually be exposed by a specific location block:

```
    location /stats {
        content_by_lua_block {
            local request_counter = require "resty.greencheek.request.counter"

            ngx.say(request_counter.stats("request_counters"))
        }
    }
```

This for example will output something similar to the following:

```
{
  "shared_dict_info": {
    "free_space": 4096,
    "capacity": 16384
  },
  "stats": {
    "topic": {
      "current": {
        "latency_ms": 200.61538461538,
        "startofminute_epoch": 1537724100,
        "requests": 13,
        "rate": 13,
        "epoch": 1537724123
      },
      "prev1": {
        "latency_ms": 0,
        "startofminute_epoch": 1537724040,
        "requests": 0
      },
      "prev2": {
        "latency_ms": 0,
        "startofminute_epoch": 1537723980,
        "requests": 0
      }
    },
    "all": {
      "current": {
        "latency_ms": 186.28571428571,
        "startofminute_epoch": 1537724100,
        "requests": 14,
        "rate": 32.610083401203
      },
      "prev1": {
        "latency_ms": 1.2950819672131,
        "startofminute_epoch": 1537724040,
        "requests": 61
      },
      "prev2": {
        "latency_ms": 0,
        "startofminute_epoch": 1537723980,
        "requests": 0
      }
    }
  }
}
```

----

# Local Testing

There's a `Dockerfile` that can be used to build a local docker image for testing.  Build the image:

```
docker build --no-cache -t counter . 
```

And then run from the root of the repo:


```
(docker rm -f counter 2>&1 >/dev/null || :) && docker run --name counter --rm -it -v $(pwd)/conf.d:/etc/nginx/conf.d -v $(pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf -v $(pwd):/data -v $(pwd)/lib/resty/greencheek/request/counter.lua:/usr/local/openresty/lualib/resty/greencheek/request/counter.lua counter:latest /bin/bash
```

when in the container run:

- `/usr/local/openresty/bin/openresty` to start openresty
- `/usr/local/openresty/bin/openresty -s stop` to stop openresty.

OpenResty will be running on port `9090`.

Gil Tene's fork of [wrk](https://github.com/giltene/wrk2) is also complied during the build of the docker image.

```
wrk -t1 -c1 -d30s -R2 http://localhost:9090/log
```

----

# See Also

* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
